module Seo
  # The questions people actually ask before choosing an analytics tool, and the
  # answers this project is willing to stand behind.
  #
  # THE CATALOGUE IS CODE, for the same reason Billing::Plan is: there are a
  # dozen entries, they change about as often as the product does, and three
  # separate things have to agree about them. /faq renders them as HTML, /faq.md
  # renders them as markdown for machine readers, and Seo::BuildStructuredData
  # renders them as schema.org FAQPage so an answer engine can quote one. A
  # database table would let those three disagree; three hand-written copies
  # guarantee it. app/views/pages/home.md.erb already carries a comment asking a
  # future editor to remember to change the other copy, which is the failure this
  # file exists to not repeat.
  #
  # EVERY ANSWER HERE IS BOUND BY docs/privacy/claims.md. That document lists the
  # sentences this category gets sued over — "no cookie banner needed", "GDPR
  # compliant", "we collect no personal data", "fully anonymous" — and the
  # honest replacement for each. This file is the single most likely place in the
  # codebase for one of them to reappear, because a FAQ is written in the
  # voice of the question and the question is usually the forbidden claim. Read
  # claims.md before editing an answer, and note that
  # spec/values/seo/faq_spec.rb fails on the banned phrasings.
  #
  # Built per call rather than frozen into a constant so that Billing::Plan and
  # Tastatur's deployment predicates are read when the page is served, not when
  # the process booted. Same reasoning as Billing::Plan#stripe_price_id: a
  # memoised answer is one that stays wrong for the life of the process after the
  # instance is reconfigured.
  module Faq
    module_function

    # The questions in the order they are shown. Ordered by what a stranger asks
    # first, which is not the order we would find most flattering: the cookie
    # banner and the compliance question lead because those are the two that
    # decide whether the rest of the page gets read.
    def entries
      all = [
        cookie_banner,
        gdpr,
        personal_data,
        ip_addresses,
        how_without_cookies,
        numbers_versus_google_analytics,
        do_not_track,
        ad_blockers,
        self_hosting,
        dpa,
        pricing
      ]

      all.compact
    end

    def find(anchor)
      entries.find { |entry| entry.anchor == anchor }
    end

    # --- The entries ---------------------------------------------------------

    def cookie_banner
      FaqEntry.new(
        anchor: "cookie-banner",
        question: "Do I need a cookie banner if I use Tastatur?",
        answer: [
          "Tastatur sets no cookies on the site it measures and reads none there. Nothing is " \
          "written to your visitors' devices at all — no localStorage, no sessionStorage, no " \
          "IndexedDB. So there is nothing of ours for a consent banner to ask permission for.",

          "In many EU and UK configurations that means Tastatur alone does not require a consent " \
          "banner. It does not mean you can remove one: if any other tool on your site needs " \
          "consent, you need the banner regardless of us, and the answer depends on your " \
          "jurisdiction. Germany is the clearest example — TDDDG §25 has no audience-measurement " \
          "exception, so the accurate position there is that we store nothing on the device and " \
          "§25 is arguably not engaged at all, never that a banner can be dropped.",

          "We will not tell you that you can skip the banner. Anyone who does is making a legal " \
          "determination about your site that they are not in a position to make."
        ],
        links: [
          FaqEntry::Link.new(label: "What Tastatur collects", route: :privacy_path)
        ]
      )
    end

    def gdpr
      FaqEntry.new(
        anchor: "gdpr",
        question: "Is Tastatur GDPR compliant?",
        answer: [
          "No product can be. Compliance is a property of a controller's entire processing " \
          "operation — your lawful basis, your notices, your retention, every other processor you " \
          "use — and no tool can confer it on you by being installed. Any vendor claiming " \
          "otherwise is selling you a badge, not a legal position.",

          "What we can tell you is what is actually true and checkable. Tastatur sets no cookies " \
          "and stores nothing on a visitor's device. The visitor identifier is scoped to one site " \
          "and stops working within 24 hours, so there is no cross-site or cross-device profile. " \
          "Geography resolves to a two-letter country code and no further. Raw IP addresses and " \
          "user-agent strings are never written to the database, a log, or disk. Retention is " \
          "yours to configure and is enforced by a job, not a promise. We will sign a data " \
          "processing agreement. The whole thing is AGPL-3.0, so every one of those claims can be " \
          "verified in the source rather than taken on trust.",

          "There is also no certification to hold. No GDPR, CNIL or ICO approval exists for this " \
          "category of product, and CNIL's evaluation tool is explicitly a self-assessment that " \
          "states it does not assess overall compliance."
        ],
        links: [
          FaqEntry::Link.new(label: "What Tastatur collects", route: :privacy_path),
          FaqEntry::Link.new(label: "Data processing agreement", route: :dpa_path)
        ]
      )
    end

    def personal_data
      FaqEntry.new(
        anchor: "personal-data",
        question: "Does Tastatur collect personal data?",
        answer: [
          "Yes, briefly, and anyone who tells you their analytics tool does not is describing " \
          "something that cannot work. Your visitors' IP addresses reach our server, because every " \
          "HTTP request on the internet carries one. An IP address is personal data under GDPR " \
          "(Breyer, C-582/14) and is expressly listed as personal information under the CCPA.",

          "What matters is what happens next. The IP and user-agent are used in memory for exactly " \
          "two things — deriving a rotating digest and looking up a country code — and are then " \
          "out of scope. Neither is written to the database, to a log, or to disk anywhere.",

          "What is stored is a truncated HMAC that is scoped to one site and one 24-hour window, a " \
          "page path with personal data stripped out of it, a referrer host, a country code, and " \
          "four coarse facts about the browser. That is the whole of it, and none of it resolves " \
          "to a person once the day's secret is destroyed."
        ],
        links: [
          FaqEntry::Link.new(label: "The full technical account", route: :privacy_path)
        ]
      )
    end

    def ip_addresses
      FaqEntry.new(
        anchor: "ip-addresses",
        question: "What happens to my visitors' IP addresses?",
        answer: [
          "They are combined with a user-agent, a site identifier and a secret that changes daily " \
          "into an HMAC-SHA-256 digest truncated to 128 bits. The IP is then used once more to " \
          "look up a two-letter country code — no region, no city, no coordinates, no network " \
          "operator — and both it and the user-agent string go out of scope.",

          "No visitor's IP address is ever persisted. It exists as a local variable while a " \
          "request is served and nowhere else, which you can check: it happens in " \
          "app/lib/ingest/identifier.rb, and the source is public.",

          "One exception, stated here rather than buried. If you hold an account on this dashboard, " \
          "we record the IP of your two most recent sign-ins so you can notice a login that was not " \
          "you. That is about you as a customer, not about visitors to any site you measure."
        ],
        links: [
          FaqEntry::Link.new(label: "What Tastatur collects", route: :privacy_path),
          FaqEntry::Link.new(label: "Privacy policy", route: :privacy_policy_path)
        ]
      )
    end

    def how_without_cookies
      FaqEntry.new(
        anchor: "how-it-works",
        question: "How can you count returning visitors without cookies?",
        answer: [
          "Within a single day, we can. A visitor's request is turned into a digest of their IP, " \
          "user-agent and the site they are on, salted with a secret held only in memory. The same " \
          "person loading a second page that day produces the same digest, so a visit holds " \
          "together and a funnel works.",

          "Across days, we cannot, and we do not pretend to. The secret is replaced every 24 hours " \
          "and the old one destroyed from a store that never writes to disk, so yesterday's digests " \
          "cannot be recomputed or matched by anyone — including us, including with the database in " \
          "hand. Each site's secret rotates at midnight in that site's own timezone, so a day on " \
          "your dashboard is a day where you are.",

          "The honest characterisation is that data derived from a live salt is pseudonymous, not " \
          "anonymous: while the secret exists the mapping is computable by whoever holds it. Once " \
          "it is destroyed the link cannot be rebuilt and the data is unlinkable. We draw that " \
          "distinction rather than describing the product as anonymous outright, because during " \
          "the salt window that would not be true."
        ],
        links: [
          FaqEntry::Link.new(label: "Why the identifier stops working every day", route: :privacy_path)
        ]
      )
    end

    def numbers_versus_google_analytics
      FaqEntry.new(
        anchor: "different-numbers",
        question: "Why don't my numbers match Google Analytics?",
        answer: [
          "They will not match, and neither figure is the truth. Ours is a good estimate rather " \
          "than a census, and it is worth knowing which direction each difference pulls in before " \
          "you go looking for a bug.",

          "Visitor counts over more than a day are the big one. Because the identifier expires " \
          "every 24 hours, a 30-day visitor figure here is the sum of 30 daily figures, not a " \
          "count of distinct people. Someone who visits on five days is five visitors. A tool " \
          "reporting cross-day uniques is keeping something durable on the device to do it.",

          "In the other direction, a cookie-based tracker is refused outright by a large share of " \
          "ad and tracker blockers, so it undercounts the technical end of your audience. Tastatur " \
          "makes one first-party request and is blocked less often, but it is not unblockable and " \
          "we make no claim that it is.",

          "There are limits inherent to the method, too. Two people behind the same office NAT " \
          "with the same browser version can collapse into one visitor; one person moving from " \
          "wifi to cellular becomes two. And breakdown rows seen by fewer than your site's " \
          "threshold of distinct visitors are withheld on purpose, so the rows in a table can sum " \
          "to less than the total above it."
        ],
        links: [
          FaqEntry::Link.new(label: "What Tastatur collects", route: :privacy_path)
        ]
      )
    end

    def do_not_track
      FaqEntry.new(
        anchor: "do-not-track",
        question: "Do you honour Do Not Track and Global Privacy Control?",
        answer: [
          "Yes, by default, and in both places — the tracking script checks before it sends " \
          "anything, and the server checks again before it records anything. If a visitor's " \
          "browser sends either signal, no identifier is computed and no event is stored. Only an " \
          "anonymous counter is incremented, so you can see that some requests opted out.",

          "There is no per-person opt-out beyond that, and there structurally cannot be. Recording " \
          "that one particular visitor has opted out would mean keeping a durable identifier for " \
          "exactly the people who asked us not to. A browser header is the right mechanism here."
        ],
        links: [
          FaqEntry::Link.new(label: "Opting out", route: :privacy_path)
        ]
      )
    end

    def ad_blockers
      FaqEntry.new(
        anchor: "ad-blockers",
        question: "Will ad blockers stop Tastatur from working?",
        answer: [
          "Some will. Tastatur is not on the large tracker blocklists by default, because it does " \
          "not do the thing those lists exist to block, but several lists take a broader view and " \
          "block anything named like analytics.",

          "You can reduce that by serving the script and the ingest endpoint from your own domain " \
          "through a reverse proxy, which the documentation covers. We are not going to help you " \
          "disguise it further than that. A visitor who has installed a blocker has expressed a " \
          "preference, and a measurement tool that defeats it has picked the wrong side of its own " \
          "argument."
        ],
        links: [
          FaqEntry::Link.new(label: "Documentation", route: :docs_path)
        ]
      )
    end

    def self_hosting
      FaqEntry.new(
        anchor: "self-hosting",
        question: "Can I run Tastatur on my own server?",
        answer: [
          "Yes. Tastatur is free software under the AGPL-3.0 and the hosted service runs the same " \
          "code you can. A self-hosted install has no plans, no event ceiling and no Stripe — it " \
          "is one environment variable, and the billing interface disappears entirely.",

          "You bring PostgreSQL with the TimescaleDB extension and a Redis, and you own every row. " \
          "Being able to read the source is also the only reason the privacy claims on this site " \
          "are worth more than a promise: you do not have to believe that IP addresses are " \
          "discarded, you can go and check."
        ],
        links: [
          FaqEntry::Link.new(label: "About", route: :about_path)
        ]
      )
    end

    def dpa
      FaqEntry.new(
        anchor: "dpa",
        question: "Do I need a data processing agreement with you?",
        answer: [
          "If you use the hosted service and GDPR or UK GDPR applies to you, then yes — Article " \
          "28(3) requires a written contract wherever a processor handles personal data on a " \
          "controller's behalf, and an IP address reaching our server is personal data. Ours is " \
          "published and we will sign it.",

          "If you self-host, you need no agreement with us at all. There is no separate processor: " \
          "you run the software and you are the only party handling the data. You may well need " \
          "agreements with your own hosting and email providers.",

          "And if GDPR and UK GDPR do not apply to you, Article 28(3) does not bind you either. We " \
          "would rather say that than let a conservative-sounding overstatement stand.",

          "For measurement data the site owner is the controller and Tastatur is the processor. " \
          "For account data — your email, your team, your billing — Tastatur is the controller. " \
          "Both are true at once and the split matters."
        ],
        links: [
          FaqEntry::Link.new(label: "Data processing agreement", route: :dpa_path)
        ]
      )
    end

    # Omitted entirely wherever there is nothing to buy — a self-hosted install,
    # or a deployment whose Stripe keys are unset. Same condition and the same
    # reasoning as the pricing entry in Seo::BuildSitemap and llms.txt: quoting a
    # price an instance cannot charge is an offer that fails at the button.
    def pricing
      return nil unless Tastatur.billing_enabled?

      free = Billing::Plan.free
      pro = Billing::Plan.pro
      delimited = ->(n) { ActiveSupport::NumberHelper.number_to_delimited(n) }

      FaqEntry.new(
        anchor: "pricing",
        question: "What does Tastatur cost?",
        answer: [
          "#{free.name} is #{delimited.call(free.monthly_event_limit)} events a month across " \
          "#{free.site_limit} #{'site'.pluralize(free.site_limit)}, with no card and no trial " \
          "clock. #{pro.name} is $#{pro.price_display} a month for " \
          "#{delimited.call(pro.monthly_event_limit)} events across #{pro.site_limit} sites.",

          "Teammates are unlimited on every plan. Per-seat pricing on an analytics tool means the " \
          "person who most needs to see the numbers is the person nobody wants to pay for, and the " \
          "shared login that follows is worse for everyone.",

          "There is no overage charge. Once an account passes its monthly allowance further events " \
          "are not recorded, and the allowance resets on the first of the month — you will never " \
          "get an invoice larger than the price above. You are emailed at 80% and again if it runs " \
          "out. Downgrading never deletes anything.",

          "Or pay nothing and self-host it, which has no limits at all."
        ],
        links: [
          FaqEntry::Link.new(label: "Pricing", route: :pricing_path)
        ]
      )
    end
  end
end
