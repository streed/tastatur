# Generates plausible-looking traffic so the dashboard can be developed and
# demonstrated without waiting for a real site to accumulate data.
#
# Writes straight to the hypertable rather than going through the ingest
# endpoint: this needs to produce months of backdated traffic in seconds, and
# the ingest path deliberately stamps everything with the current time.
namespace :tastatur do
  desc "Generate demo analytics data (DAYS=90 SITE=domain.com)"
  task demo_data: :environment do
    days = Integer(ENV.fetch("DAYS", "90"))

    # `site_limit_override` because the free plan allows one site and this task is
    # commonly re-run with a different SITE= to demonstrate more than one. An
    # override rather than putting the demo account on `pro`, so nothing here
    # pretends to be a paying customer.
    account = Account.find_or_create_by!(name: "Demo Account") { |a| a.site_limit_override = 20 }
    account.update!(site_limit_override: 20) if account.site_limit_override.blank?
    user = User.find_by(email: "user@example.com")
    if user && !user.member_of?(account)
      Membership.find_or_create_by!(account: account, user: user, role: "owner")
    end

    site = Site.find_or_create_by!(account: account, domain: ENV.fetch("SITE", "demo.example.com"))

    PAGES = [
      ["/",                0.34],
      ["/pricing",         0.16],
      ["/docs",            0.14],
      ["/blog/why-cookieless-analytics", 0.12],
      ["/blog/gdpr-without-banners",     0.09],
      ["/features",        0.07],
      ["/about",           0.04],
      ["/changelog",       0.04]
    ].freeze

    SOURCES = [
      ["Direct",       nil,                     0.38],
      ["Google",       "google.com",            0.24],
      ["Hacker News",  "news.ycombinator.com",  0.13],
      ["X (Twitter)",  "t.co",                  0.09],
      ["Reddit",       "reddit.com",            0.07],
      ["LinkedIn",     "linkedin.com",          0.05],
      ["DuckDuckGo",   "duckduckgo.com",        0.04]
    ].freeze

    # The funnels this site gets, and the journeys that fill them in.
    #
    # The traffic above picks every page independently, which is right for a
    # breakdown and useless for a funnel: a step is reached only by somebody who
    # reached the one before it, so independently-drawn pages give a funnel whose
    # steps wander up and down and whose drop-off means nothing. These visitors
    # walk a declared route instead and leave it at a fixed rate per step.
    #
    # `match` is what the STEP matches — one entry, or several for a step
    # satisfied by any of them. `visit` is what the walker actually does, and is
    # needed wherever the two differ: a step matching /docs by prefix is reached
    # by a visit to /docs/api, and there is no visiting a wildcard at all.
    # `keep` is the share of the previous step's walkers who take this one.
    FUNNEL_SPECS = [
      { name: "Signup flow", window: 1.hour.to_i, daily: 34,
        steps: [
          { name: "Landed", match: [%w[pageview /]], keep: 1.0 },
          { name: "Saw pricing", match: [%w[pageview /pricing]], keep: 0.52 },
          { name: "Opened the form", match: [%w[pageview /signup]], keep: 0.44 },
          # Two ways to finish, which is the ordinary shape of a last step: the
          # event fires for anyone who completes, and the welcome page catches
          # the visitor whose beacon was blocked.
          { name: "Signed up", match: [%w[event Signup], %w[pageview /welcome]],
            visit: %w[event Signup], keep: 0.61 }
        ] },
      { name: "Docs to trial", window: 2.days.to_i, daily: 18,
        steps: [
          { name: "Read the docs", match: [["pageview", "/docs", "prefix"]],
            visit: %w[pageview /docs/api], keep: 1.0 },
          { name: "Started a trial", match: [["event", "Start trial"]], keep: 0.29 }
        ] },
      { name: "Checkout", window: 30.minutes.to_i, daily: 12,
        steps: [
          # One step, two names for the same page — the site was renamed and the
          # old path is still linked from the newsletter.
          { name: "Cart", match: [%w[pageview /cart], %w[pageview /basket]],
            visit: %w[pageview /cart], keep: 1.0 },
          { name: "Payment details", match: [%w[pageview /checkout]], keep: 0.71 },
          { name: "Paid", match: [["event", "Purchase"]], keep: 0.66 }
        ] },
      # Deliberately poor, because a list of funnels that all convert well is not
      # a list anybody has to read carefully.
      { name: "Blog to signup", window: 6.hours.to_i, daily: 40,
        steps: [
          { name: "Read a post", match: [["pageview", "/blog/", "prefix"]],
            visit: %w[pageview /blog/why-cookieless-analytics], keep: 1.0 },
          { name: "Saw pricing", match: [%w[pageview /pricing]], keep: 0.11 },
          { name: "Signed up", match: [%w[event Signup]], keep: 0.24 }
        ] }
    ].freeze

    COUNTRIES = [["DE", 0.26], ["US", 0.24], ["GB", 0.11], ["FR", 0.08], ["NL", 0.07],
                 ["AT", 0.06], ["CH", 0.05], ["CA", 0.05], ["SE", 0.04], ["ES", 0.04]].freeze
    BROWSERS = [["Chrome", 0.52], ["Safari", 0.21], ["Firefox", 0.17], ["Edge", 0.10]].freeze
    SYSTEMS  = [["Mac", 0.36], ["Windows", 0.31], ["iOS", 0.16], ["Android", 0.11], ["GNU/Linux", 0.06]].freeze

    def pick(weighted, rng)
      roll = rng.rand
      cumulative = 0.0
      weighted.each do |entry|
        cumulative += entry.last
        return entry if roll <= cumulative
      end
      weighted.last
    end

    rng = Random.new(20_260_729)
    rows = []
    now = Time.current.beginning_of_hour

    (0...days).each do |day_offset|
      date = now - day_offset.days
      # Weekends are quieter, and there is a gentle upward trend toward today.
      weekday_factor = date.on_weekend? ? 0.55 : 1.0
      growth = 1.0 + ((days - day_offset).to_f / days) * 0.8
      visitors_today = (rng.rand(40..90) * weekday_factor * growth).round

      visitors_today.times do |visitor_index|
        visitor = OpenSSL::Digest::SHA256.digest("demo-#{day_offset}-#{visitor_index}").byteslice(0, 16)
        session = OpenSSL::Digest::SHA256.digest("demo-s-#{day_offset}-#{visitor_index}").byteslice(0, 16)

        source, referrer_host, = pick(SOURCES, rng)
        country, = pick(COUNTRIES, rng)
        browser, = pick(BROWSERS, rng)
        os, = pick(SYSTEMS, rng)
        device = %w[iOS Android].include?(os) ? "mobile" : "desktop"

        # Office hours get most of the traffic.
        hour = [rng.rand(0..23), rng.rand(8..20)].sample(random: rng)
        started = date.change(hour: hour, min: rng.rand(0..59))

        # Most visits are one page; some go deeper.
        depth = rng.rand < 0.55 ? 1 : rng.rand(2..5)

        depth.times do |step|
          page, = pick(PAGES, rng)
          rows << {
            occurred_at: started + (step * rng.rand(20..180)).seconds,
            site_id: site.id, event_name: "pageview",
            visitor_hash: visitor, session_hash: session, is_entry: step.zero?,
            hostname: site.domain, path: step.zero? ? page : pick(PAGES, rng).first,
            referrer_host: referrer_host, referrer_source: source,
            utm_source: (["newsletter", nil, nil, nil].sample(random: rng) if source == "Direct"),
            utm_medium: nil, utm_campaign: nil, utm_term: nil, utm_content: nil,
            country_code: country, browser: browser, browser_version: rng.rand(115..131).to_s,
            os: os, os_version: rng.rand(10..18).to_s, device_type: device,
            screen_class: device == "mobile" ? "xs" : %w[lg xl].sample(random: rng),
            revenue_cents: nil, currency: nil, props: nil
          }
        end

        # A slice of deeper visits convert.
        next unless depth > 2 && rng.rand < 0.22

        rows << rows.last.merge(
          occurred_at: rows.last[:occurred_at] + rng.rand(30..300).seconds,
          event_name: "Signup", is_entry: false, path: "/pricing",
          props: { "plan" => Billing::Plan::OFFERED.map(&:key).sample(random: rng) }
        )
      end

      # --- The funnel walkers for this day ---------------------------------
      #
      # One visitor per walk, one session per walk, every step inside the
      # funnel's own window — a walk that overran it would be a funnel that
      # reports a drop-off nobody actually took. Each walker also carries the
      # ordinary dimensions, so filtering the funnel by country or browser has
      # something to filter.
      FUNNEL_SPECS.each_with_index do |funnel, funnel_index|
        walkers = (funnel[:daily] * weekday_factor * growth).round

        walkers.times do |walker_index|
          seed = "funnel-#{funnel_index}-#{day_offset}-#{walker_index}"
          # Hex, not raw bytes: Ingest::WriteBuffer un-hexes whatever it is
          # given on the way out of Redis, so raw bytes are silently
          # reinterpreted as hex digits and stored half the width.
          walker = OpenSSL::Digest::SHA256.digest(seed).byteslice(0, 16).unpack1("H*")

          source, referrer_host, = pick(SOURCES, rng)
          country, = pick(COUNTRIES, rng)
          browser, = pick(BROWSERS, rng)
          os, = pick(SYSTEMS, rng)
          device = %w[iOS Android].include?(os) ? "mobile" : "desktop"

          at = date.change(hour: rng.rand(7..21), min: rng.rand(0..59))
          elapsed = 0
          last_path = "/"

          funnel[:steps].each_with_index do |step, step_index|
            break if rng.rand > step[:keep]

            kind, value = step[:visit] || step[:match].first
            # A custom event fires on some page, and the truthful one is the
            # page this walker is standing on.
            page = kind == "event" ? last_path : value
            last_path = page
            # Spread over the window rather than a fixed gap, so the report is
            # not a single spike, and never past it.
            elapsed += rng.rand(20..(funnel[:window] / (funnel[:steps].size + 1)))

            rows << {
              occurred_at: at + elapsed.seconds,
              site_id: site.id,
              event_name: kind == "event" ? value : "pageview",
              visitor_hash: walker, session_hash: walker, is_entry: step_index.zero?,
              hostname: site.domain, path: page,
              referrer_host: referrer_host, referrer_source: source,
              utm_source: nil, utm_medium: nil, utm_campaign: nil, utm_term: nil, utm_content: nil,
              country_code: country, browser: browser, browser_version: rng.rand(115..131).to_s,
              os: os, os_version: rng.rand(10..18).to_s, device_type: device,
              screen_class: device == "mobile" ? "xs" : %w[lg xl].sample(random: rng),
              revenue_cents: nil, currency: nil, props: nil
            }
          end
        end
      end
    end

    puts "Inserting #{rows.size} events for #{site.domain}..."
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array(["DELETE FROM events WHERE site_id = ?", site.id])
    )
    rows.each_slice(2_000) { |slice| Ingest::WriteBuffer.insert_all(slice.map(&:stringify_keys)) }

    puts "Refreshing continuous aggregates..."
    %w[events_by_hour visitor_days session_days].each do |view|
      ActiveRecord::Base.connection.execute("CALL refresh_continuous_aggregate('#{view}', NULL, NULL)")
    end

    site.update!(first_event_at: rows.map { |r| r[:occurred_at] }.min)

    # The funnels the walks above were built to fill in. Rebuilt from the
    # declaration every run rather than merged into: a step edited here and a
    # step already in the database are two different funnels wearing one name,
    # and the one that reports is the stored one.
    puts "Building funnels..."
    FUNNEL_SPECS.each do |spec|
      funnel = site.funnels.find_or_initialize_by(name: spec[:name])
      funnel.window_seconds = spec[:window]
      funnel.funnel_steps.destroy_all

      spec[:steps].each_with_index do |step, index|
        row = funnel.funnel_steps.build(position: index + 1, name: step[:name])

        step[:match].each_with_index do |(kind, value, match_type), condition_index|
          row.conditions.build(position: condition_index + 1, kind: kind,
                               match_value: value, match_type: match_type || "exact")
        end
      end

      funnel.save!
      report = Analytics::FunnelReport.call(
        funnel: funnel, period: Analytics::Period.parse("30d", site: site)
      ).value!
      puts format("  %-16s %5d entered  %5d completed  %5.1f%%",
                  funnel.name, report.entered, report.completed, report.overall_rate)
    end

    # These rows went in through the write buffer, which bypasses
    # Ingest::RecordEvent and therefore the usage meter — so the plan screen would
    # read zero events against months of stored traffic until the hourly
    # reconciliation caught up. `notify: false` because nobody wants a
    # "you are near your limit" email from seeding demo data.
    Billing::ReconcileUsage.call(notify: false) if Tastatur.billing_enabled?

    puts "Done. Site token: #{site.public_token}"
  end
end
