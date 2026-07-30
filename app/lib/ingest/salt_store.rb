module Ingest
  # The rotating secret that makes visitor identity unlinkable across days.
  #
  # Every visitor hash is HMAC-SHA256(salt, site_id ‖ ip ‖ user_agent). Because
  # the salt is replaced daily and the old value is destroyed, yesterday's
  # hashes cannot be recomputed or joined to today's — not by an attacker who
  # steals the database, and not by us. That property is the entire basis for
  # calling the stored data anonymous rather than merely pseudonymous, so the
  # rules below are load-bearing:
  #
  #   1. The salt lives ONLY in Redis, never in PostgreSQL. A database backup
  #      or a leaked dump must not contain the one secret that would let
  #      someone re-identify the events stored alongside it.
  #
  #   2. Exactly two salts exist per site at a time: current, and the one it
  #      replaced. Rotating to a single new salt would sever every in-flight
  #      session and inflate the visitor count every night. The previous salt is
  #      kept only long enough for those sessions to end, then dropped.
  #
  #   3. Nothing here ever accepts a salt from outside. There is no setter, no
  #      seed, no fixture — a salt that could be pinned could be used to build
  #      a rainbow table over the IPv4 space.
  #
  # ## Salts are per site, and roll over at that site's local midnight
  #
  # There used to be one instance-wide salt rotated by a nightly Sidekiq job at
  # 04:07 server time. That is wrong in a way that is invisible on a dashboard
  # and shows up as inflated numbers:
  #
  # **A day on the dashboard is a day in the site's timezone.** `Analytics::Period`
  # builds every range in `site.timezone` and `Analytics::Scope` buckets with
  # `time_bucket(..., site.timezone)`. So for a site in America/Los_Angeles the
  # reporting day ran 07:00 UTC to 07:00 UTC — and a salt rotating at 04:07 UTC
  # rotated at 20:07 the previous *local* evening, three hours inside that day.
  # One person browsing at 20:00 and again at 20:15 hashed to two different
  # visitors and was counted twice, in the same day, on the same report. Only a
  # site actually set to UTC was measured over the window it was shown.
  #
  # Rotating at the site's own local midnight makes the salt window and the
  # reporting day the same window, which is the only arrangement in which
  # "unique visitors today" means what it says.
  #
  # ## There is no rotation job, and that is the point
  #
  # The salt's Redis key carries the site and the site-local date it belongs to,
  # so "which salt is current" is a question about the clock rather than about
  # whether a cron entry fired. Rotation happens at local midnight because the
  # date in the key changes then; the retired key is destroyed by its own TTL.
  #
  # That removes a failure mode nothing was watching. A skipped or wedged
  # rotation job left yesterday's salt live indefinitely, and the symptom of the
  # product quietly ceasing to be anonymous was *nothing at all*. It also serves
  # zones a cron schedule cannot: Asia/Kolkata (+05:30), Asia/Kathmandu (+05:45)
  # and Pacific/Chatham (+12:45) have local midnights no hourly job can hit.
  #
  # **The date names the key; it does not produce the secret.** The value stored
  # under that name is `SecureRandom` and is never recomputed from anything. The
  # construction docs/privacy/identity.md rejects — running a key-derivation
  # function over a long-lived secret and the date — derives the *value*, which
  # is what makes every historical salt regenerable forever and destruction a
  # fiction. Superficially these look alike and they are opposites, so
  # `spec/privacy_invariants_spec.rb` holds the line.
  #
  # See docs/privacy/identity.md for the full reasoning and the regulator-facing
  # version of this argument.
  module SaltStore
    KEY_PREFIX = "tastatur:salt:".freeze
    SALT_BYTES = 32

    # How long a retired salt stays readable after the local day it belonged to
    # has ended. Generous enough that a session started just before midnight can
    # still be matched, short enough that the window is plainly bounded — a salt
    # is gone at most 48 hours after it was first used.
    PREVIOUS_TTL = 24.hours

    # A site whose timezone is unset or unrecognised still has to hash to
    # something, and the column defaults to Etc/UTC, so this is a belt for a
    # value that predates the validation rather than an expected path.
    FALLBACK_ZONE = ActiveSupport::TimeZone["Etc/UTC"].freeze

    module_function

    # The salt to hash NEW events with, minting one if this is the site's first
    # event of the local day.
    def current(site)
      now = local_now(site)
      key = key_for(site, now.to_date)

      PRIVACY_REDIS_POOL.with do |redis|
        existing = redis.get(key)
        next existing if existing.present?

        # SET ... NX EX is one atomic command, so concurrent web workers racing
        # on the first event after midnight cannot each install a different salt
        # and split the same visitor into several.
        fresh = SecureRandom.bytes(SALT_BYTES).unpack1("H*")
        redis.set(key, fresh, ex: ttl_from(now), nx: true)
        Rails.logger.info("[tastatur] minted a visitor salt for site #{site.id} (#{now.to_date} #{now.time_zone.name})")
        redis.get(key)
      end
    end

    # The salt in use before the last local midnight, or nil. Used only to
    # recognise a session that began before the rollover; never used to write
    # new events, and deliberately never mints one — a site with no salt for
    # yesterday had no traffic to carry over.
    def previous(site)
      PRIVACY_REDIS_POOL.with { |redis| redis.get(key_for(site, local_now(site).to_date.prev_day)) }
    end

    # Whether the store the salts live in is reachable at all, for the admin
    # health panel. There is no instance-wide salt to look for any more, and
    # "some site has one" would answer a question nobody is asking: what an
    # operator needs to know is whether the privacy Redis is up, because if it
    # is not then no event can be identified and ingest is dropping everything.
    def available?
      PRIVACY_REDIS_POOL.with { |redis| redis.ping.present? }
    end

    # Emergency control offered to operators: drops every site's salts
    # immediately, so every stored visitor hash becomes permanently unlinkable to
    # any future observation. Exposed as `rails tastatur:privacy:purge_salts`.
    #
    # THE SESSION MAP GOES TOO. This used to delete only the salt keys while
    # logging "ALL visitor salts destroyed", and left every
    # `tastatur:session:<site>:<visitor_hash>` entry in place. Those keys contain a
    # visitor hash by construction, and they are the live mapping from a visitor to
    # their current session — exactly the linkable state an operator pressing this
    # button is trying to be rid of. Verified before the fix: after destroy_all!,
    # the session keys were still there.
    #
    # BOTH POOLS, when they are not the same server. With REDIS_PRIVACY_URL unset
    # the two constants are literally the same object and one pass covers it; when
    # it is set they are different, and sweeping the persistent instance as well
    # costs one extra SCAN and catches salts left behind by an instance that ran
    # unconfigured before the operator split them apart. Compared on the resolved
    # URL rather than object identity, because two pools can point at one server.
    def destroy_all!
      pools.each do |pool|
        pool.with do |redis|
          # SCAN rather than KEYS: this runs on a live instance, and KEYS blocks the
          # server for the length of the sweep. The salt keys are swept the same way
          # now that there is one per site per day rather than two in total.
          [KEY_PREFIX, SessionWindow::KEY_PREFIX].each do |prefix|
            redis.scan_each(match: "#{prefix}*", count: 1_000) { |key| redis.del(key) }
          end
        end
      end

      Rails.logger.warn("[tastatur] ALL visitor salts and session mappings destroyed")
      :destroyed
    end

    # Deduplicated by the server they resolve to.
    def pools
      return [PRIVACY_REDIS_POOL] if PRIVACY_REDIS_POOL.equal?(REDIS_POOL)
      return [PRIVACY_REDIS_POOL] if ENV["REDIS_PRIVACY_URL"].to_s == ENV["REDIS_URL"].to_s

      [PRIVACY_REDIS_POOL, REDIS_POOL]
    end

    # The site id, not the public token: the token is printed in a script tag on
    # a public page, and a Redis key naming it would let anyone who read the page
    # ask a compromised Redis for that site's salt by name.
    def key_for(site, date)
      "#{KEY_PREFIX}#{site.id}:#{date.iso8601}"
    end

    # Read once and reused for both the date and the TTL, so a call that straddles
    # midnight cannot file a salt under today's date with yesterday's lifetime.
    def local_now(site)
      Time.current.in_time_zone(zone_for(site))
    end

    def zone_for(site)
      ActiveSupport::TimeZone[site.timezone.to_s] || FALLBACK_ZONE
    end

    # Expire 24 hours after the local day this salt belongs to ends, whenever
    # within that day it was minted. That is what keeps exactly two salts alive
    # per site: while day D is current, D's key and D-1's key exist, and D-2's
    # expired when D-1 ended.
    #
    # Derived from `end_of_day` on a zoned time rather than by adding 86,400
    # seconds, because a local day is 23 or 25 hours long on the two DST
    # changeover dates and a fixed-length day would retire the salt an hour early
    # or an hour late.
    def ttl_from(local_now)
      (local_now.end_of_day - local_now).to_i + PREVIOUS_TTL.to_i
    end
  end
end
