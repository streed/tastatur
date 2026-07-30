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

    # These rows went in through the write buffer, which bypasses
    # Ingest::RecordEvent and therefore the usage meter — so the plan screen would
    # read zero events against months of stored traffic until the hourly
    # reconciliation caught up. `notify: false` because nobody wants a
    # "you are near your limit" email from seeding demo data.
    Billing::ReconcileUsage.call(notify: false) unless Tastatur.self_hosted?

    puts "Done. Site token: #{site.public_token}"
  end
end
