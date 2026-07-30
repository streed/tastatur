module Ingest
  # The rotating secret that makes visitor identity unlinkable across days.
  #
  # Every visitor hash is SHA-256(salt || site_id || ip || user_agent). Because
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
  #   2. Exactly two salts exist at a time: current, and the one it replaced.
  #      Rotating to a single new salt at midnight would sever every in-flight
  #      session and inflate the visitor count every night. The previous salt
  #      is kept only long enough for those sessions to end, then dropped.
  #
  #   3. Nothing here ever accepts a salt from outside. There is no setter, no
  #      seed, no fixture — a salt that could be pinned could be used to build
  #      a rainbow table over the IPv4 space.
  #
  # See docs/privacy/identity.md for the full reasoning and the regulator-facing
  # version of this argument.
  module SaltStore
    CURRENT_KEY = "tastatur:salt:current".freeze
    PREVIOUS_KEY = "tastatur:salt:previous".freeze
    SALT_BYTES = 32

    # Generous enough that a session started just before rotation can still be
    # matched, short enough that the window is plainly bounded. The salt is
    # gone at most 48h after it was first used.
    PREVIOUS_TTL = 24.hours

    module_function

    # The salt to hash NEW events with.
    def current
      PRIVACY_REDIS_POOL.with do |redis|
        existing = redis.get(CURRENT_KEY)
        next existing if existing.present?

        # First boot, or Redis was flushed. Create one atomically so concurrent
        # web workers cannot each install a different salt and split the same
        # visitor into several.
        fresh = SecureRandom.bytes(SALT_BYTES).unpack1("H*")
        redis.set(CURRENT_KEY, fresh, nx: true)
        redis.get(CURRENT_KEY)
      end
    end

    # The salt in use before the last rotation, or nil. Used only to recognise
    # a session that began before midnight; never used to write new events.
    def previous
      PRIVACY_REDIS_POOL.with { |redis| redis.get(PREVIOUS_KEY) }
    end

    # Promote current -> previous and install a fresh current. Called daily by
    # RotateVisitorSaltJob. Deliberately not atomic across the two keys: the
    # worst case is a single event hashed with a salt that is a moment stale,
    # which costs one visitor a session boundary and leaks nothing.
    def rotate!
      PRIVACY_REDIS_POOL.with do |redis|
        outgoing = redis.get(CURRENT_KEY)
        fresh = SecureRandom.bytes(SALT_BYTES).unpack1("H*")

        redis.multi do |tx|
          # Overwriting PREVIOUS_KEY is what destroys the salt from two days
          # ago. There is no archive and no way back.
          tx.set(PREVIOUS_KEY, outgoing, ex: PREVIOUS_TTL.to_i) if outgoing.present?
          tx.set(CURRENT_KEY, fresh)
        end
      end

      Rails.logger.info("[tastatur] visitor salt rotated")
      :rotated
    end

    # Emergency control offered to operators: drops both salts immediately, so
    # every stored visitor hash becomes permanently unlinkable to any future
    # observation. Exposed as `rails tastatur:privacy:purge_salts`.
    #
    # THE SESSION MAP GOES TOO. This used to delete only the two salt keys while
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
          redis.del(CURRENT_KEY, PREVIOUS_KEY)
          # SCAN rather than KEYS: this runs on a live instance, and KEYS blocks the
          # server for the length of the sweep.
          redis.scan_each(match: "#{SessionWindow::KEY_PREFIX}*", count: 1_000) { |key| redis.del(key) }
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
  end
end
