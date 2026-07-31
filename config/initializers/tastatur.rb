# frozen_string_literal: true

# Deployment-mode configuration.
#
# Tastatur ships as one codebase in two shapes: the hosted SaaS, and an
# AGPL-licensed self-hosted install. Everything that differs between them is
# decided here, so no feature has to reach for `Rails.env` or guess.

module Tastatur
  # Set SELF_HOSTED=1 to run without billing. In this mode Stripe is never
  # touched, plan limits do not apply, and the upgrade UI is hidden — a
  # self-hosted operator should never see a paywall in software they are
  # running on their own hardware.
  def self.self_hosted?
    @self_hosted = ENV.fetch("SELF_HOSTED", "0") == "1" if @self_hosted.nil?
    @self_hosted
  end

  # Can this instance actually take money?
  #
  # WHY THIS IS SEPARATE FROM `self_hosted?`. There are two reasons billing might
  # not work, and only one of them is a deliberate choice. A self-hosted operator
  # has switched it off. A hosted deployment with no Stripe keys has not switched
  # anything off — it is half-configured, and until this predicate existed that
  # produced the worst possible state: plan limits enforced, so every account was
  # capped at one site and 100,000 events, with an upgrade button that could only
  # answer "payments are not configured on this instance". A paywall with no
  # cashier. Nobody chose that, and nothing said so.
  #
  # So configuration is treated exactly like deployment mode: until Stripe is
  # wired up, billing does not exist. No limits, no upgrade interface, no pricing
  # page, no webhook endpoint, no Stripe calls. The moment the variables are set it
  # comes on by itself, with no migration and no restart-order dance.
  #
  # WHAT COUNTS AS CONFIGURED, and why each part:
  #
  #   STRIPE_SECRET_KEY      nothing can be created at Stripe without it
  #   STRIPE_WEBHOOK_SECRET  without it every delivery is refused, so a
  #                          subscription is paid for and never applied — the one
  #                          failure that is invisible from the outside
  #   a price for one plan   there has to be something to sell
  #
  # STRIPE_PUBLISHABLE_KEY is deliberately NOT required: payment happens on
  # Stripe's hosted Checkout, so this application renders no card form and loads no
  # Stripe.js. Requiring a variable nothing reads would mean a deployment that is
  # correct being told it is broken.
  #
  # `any?` rather than `all?` on the prices, so a second paid plan added later
  # without a price id degrades to "that one plan cannot be bought"
  # (Billing::StartCheckout returns `price_not_configured`) instead of taking the
  # whole billing system down with it.
  def self.billing_configured?
    stripe = Rails.configuration.stripe

    stripe[:secret_key].present? &&
      stripe[:webhook_secret].present? &&
      Billing::Plan.purchasable_plans.any?(&:configured?)
  end

  # Can this instance SELL? Plan limits, the pricing page, checkout and the upgrade
  # interface all ask this.
  #
  # Deliberately NOT memoized: it is read on the ingest path, but `self_hosted?`
  # short-circuits it there for the deployment that cares most, and the remaining
  # work is three `present?` calls. A memo would buy that back at the price of a
  # stale answer after the configuration changes, which is the bug this predicate
  # exists to prevent.
  def self.billing_enabled?
    !self_hosted? && billing_configured?
  end

  # Can this instance MANAGE a subscription somebody already has? A different
  # question, and conflating the two was a real mistake.
  #
  # Stripe keeps charging an existing subscriber whatever our environment holds. So
  # when a deployment loses `STRIPE_PRICE_PRO` — leaving the API key perfectly valid
  # — gating the customer portal on `billing_enabled?` took away the only place in
  # the product where somebody can cancel, update a card or read an invoice
  # (Billing::StartPortalSession is deliberately the whole of it), while the money
  # kept going out. Taking payment and removing the cancel button is not a state to
  # arrive at by misconfiguration.
  #
  # The portal needs the API key and nothing else — no price, no webhook secret — so
  # that is all this asks for. Selling stays behind `billing_enabled?`; managing what
  # is already sold stays available.
  def self.billing_manageable?
    !self_hosted? && Rails.configuration.stripe[:secret_key].present?
  end

  # Can this instance read a customer's Stripe revenue?
  #
  # DELIBERATELY NOT GATED ON `billing_enabled?`, and getting this wrong would be
  # the §14 mistake in reverse. Billing is about whether WE can charge; this is
  # about whether a customer can connect THEIR payment processor to see their own
  # attribution. A self-hosted install has no billing by definition and has every
  # reason to want revenue analytics — refusing it there would remove the entire
  # point of the product from the deployment most likely to be evaluating it.
  #
  # So the only question asked is whether the Connect integration is configured.
  # Three variables, and each is genuinely required:
  #
  #   STRIPE_SECRET_KEY              every connected-account call is made with it
  #   STRIPE_CONNECT_CLIENT_ID       there is no OAuth flow without it
  #   STRIPE_CONNECT_WEBHOOK_SECRET  without it every delivery is refused, so a
  #                                  connection succeeds and then silently never
  #                                  reports a single dollar
  #
  # The third is the one worth requiring up front rather than discovering later.
  # Its absence is invisible: connecting works, the backfill works, the screen
  # shows historical revenue, and nothing new ever arrives.
  def self.revenue_enabled?
    stripe = Rails.configuration.stripe

    stripe[:secret_key].present? &&
      stripe[:connect_client_id].present? &&
      stripe[:connect_webhook_secret].present?
  end

  # Public signup. The hosted SaaS wants it on. A self-hosted instance exposed
  # to the internet usually does not, so it defaults off there and is opened
  # back up with ALLOW_SIGNUP=1.
  def self.allow_signup?
    default = self_hosted? ? "0" : "1"
    ENV.fetch("ALLOW_SIGNUP", default) == "1"
  end

  # A brand-new self-hosted install has no users. Rather than making the
  # operator run `rails console`, the first request is redirected into a setup
  # wizard that creates the owner account and first site.
  def self.needs_first_run_setup?
    self_hosted? && !User.exists?
  end

  # Absolute URL of the tracking script, which lives on the customer's pages
  # and therefore must be absolute and stable.
  def self.tracker_url
    ENV.fetch("TRACKER_URL") { "#{base_url}/t.js" }
  end

  def self.ingest_url
    ENV.fetch("INGEST_URL") { "#{base_url}/api/event" }
  end

  # The site key this instance reports ITS OWN usage to, if any.
  #
  # Unset by default, and that default is the point. A self-hosted install must
  # never report its operator's dashboard usage anywhere, least of all to us —
  # an analytics tool that measures the people running it has picked the wrong
  # side of its own argument. The hosted service sets this to the key of the
  # tastatur.dev site in its own account, so Tastatur is measured by Tastatur
  # under exactly the privacy rules it sells.
  def self.self_measurement_token
    ENV["SELF_MEASUREMENT_SITE_TOKEN"].presence
  end

  def self.base_url
    host = ENV.fetch("APP_HOST", "localhost:3000")
    scheme = host.start_with?("localhost", "127.0.0.1") ? "http" : "https"
    "#{scheme}://#{host}"
  end

  # How long a visitor may be idle before their next event starts a new
  # session. Thirty minutes is the long-standing convention across analytics
  # tools; matching it keeps our numbers comparable to whatever the customer
  # was using before.
  def self.session_timeout
    Integer(ENV.fetch("SESSION_TIMEOUT_MINUTES", "30")).minutes
  end

  def self.version
    @version ||= File.read(Rails.root.join("VERSION")).strip
  rescue Errno::ENOENT
    "0.0.0-dev"
  end

  # --- How this instance describes itself -----------------------------------
  #
  # One sentence, in one place, because five separate things quote it and they
  # were quoting it separately: the llms.txt blockquote, the meta description on
  # the marketing page, the og:description a link preview renders, and the
  # `description` field of both the WebSite and SoftwareApplication nodes in
  # Seo::BuildStructuredData. Four of those five are invisible in a browser, so a
  # drifting copy is not something anybody would notice by looking at the site.
  #
  # It is bound by docs/privacy/claims.md like every other claim we publish. The
  # size is the measured gzipped size of lib/tracker/t.js — re-measure it here if
  # the script changes rather than rounding it in the direction we would prefer.
  DESCRIPTION = "Cookieless, privacy-first web analytics. One script tag, 4.4 KB over the wire. " \
                "No cookies, no device storage, no fingerprinting, and visitor identifiers stop " \
                "working after 24 hours.".freeze

  # The image a link preview shows when somebody pastes a URL from this instance
  # into Slack, a group chat or a social network.
  #
  # Defaults to /icon.png, which is 512x512 and therefore above every consumer's
  # minimum, but is a square app icon rather than a designed 1200x630 card. A
  # deployment that wants a real one sets SOCIAL_IMAGE_URL instead of editing a
  # template — same reasoning as TRACKER_URL: this is instance presentation, not
  # application behaviour, and a self-hosted install should not have to fork a
  # view to put its own name on its own link previews.
  #
  # `base` is required rather than defaulted to base_url, because og:image is
  # ignored outright unless it is absolute and the host has to be the one the
  # visitor actually asked for — the same rule as the Sitemap: line in
  # robots.txt.
  def self.social_image_url(base:)
    ENV["SOCIAL_IMAGE_URL"].presence || "#{base}/icon.png"
  end

  # Whether a deployment has supplied a card of its own, which is a different
  # question from what the URL is: the shipped default is a square 512x512 app
  # icon and the wide `summary_large_image` card format letterboxes a square
  # into bars. Asked by SeoHelper so the view layer does not have to know the
  # name of an environment variable — every other deployment decision in this
  # application is a predicate on this module, and this one is no different.
  def self.social_image_configured?
    ENV["SOCIAL_IMAGE_URL"].present?
  end

  # --- Authorship -----------------------------------------------------------
  #
  # Who BUILT Tastatur, which is a fixed fact and true of every copy of it.
  #
  # Deliberately separate from `legal` below, which is who OPERATES a particular
  # instance. On the hosted service they are the same; on a self-hosted install
  # they are not, and conflating them would either misattribute the software or
  # name the wrong controller in a privacy policy. Authorship is hardcoded
  # because it does not vary; the operator is environment-driven because it does.
  MAINTAINER = {
    name: "Reedster LLC",
    url: "https://reedster.llc",
    tagline: "Solve human problems with software",
    source: "https://github.com/streed/tastatur"
  }.freeze

  def self.maintainer
    MAINTAINER
  end

  # --- Legal identity -------------------------------------------------------
  #
  # A privacy policy naming nobody, and terms governed by no jurisdiction, are
  # worse than none: they look like diligence while providing neither the
  # disclosure the law requires nor the protection the operator wanted.
  #
  # So these have no plausible defaults. When they are unset, the pages render a
  # loud unconfigured banner instead of quietly publishing "Example Ltd". A
  # self-hoster who never fills them in is told so on the page rather than
  # discovering it in a complaint.
  def self.legal
    @legal ||= {
      entity: ENV["LEGAL_ENTITY"].presence,
      address: ENV["LEGAL_ADDRESS"].presence,
      email: ENV["LEGAL_EMAIL"].presence,
      jurisdiction: ENV["LEGAL_JURISDICTION"].presence,
      dpo_email: ENV["LEGAL_DPO_EMAIL"].presence,
      updated_on: legal_updated_on
    }
  end

  # The date the policy and terms were last actually revised.
  #
  # Both pages rendered `Date.current`, so they claimed to have been updated today,
  # every day, forever. That is worse than having no date at all: a reader checking
  # whether the terms changed since they last agreed to them is told "today" no
  # matter what, and a document that appears to be revised daily invites the
  # question of what keeps changing.
  #
  # Returns nil when unset, and the pages then say nothing rather than inventing a
  # date. Set LEGAL_UPDATED_ON to an ISO date when you edit them.
  # `Date.iso8601`, not `Date.parse`. The latter is startlingly lenient: it reads
  # "last tuesday" as a real date, because it recognises the day name and fills in
  # the rest. A typo in a config file then becomes a confident, wrong date printed
  # on a legal document. Strict parsing turns the same typo into a warning and no
  # date at all, which is the failure everyone would prefer.
  def self.legal_updated_on
    raw = ENV["LEGAL_UPDATED_ON"].presence
    return nil if raw.nil?

    Date.iso8601(raw)
  rescue Date::Error
    Rails.logger.warn(
      "[tastatur] LEGAL_UPDATED_ON is not an ISO date (YYYY-MM-DD): #{raw.inspect}. No date will be shown."
    )
    nil
  end

  def self.legal_configured?
    legal.values_at(:entity, :email, :jurisdiction).all?(&:present?)
  end

  # Falls back to a bracketed placeholder that is obviously unfilled, so it
  # cannot be mistaken for a real value if the banner is ever removed.
  def self.legal_value(key)
    legal[key].presence || "[#{key.to_s.tr('_', ' ').upcase} NOT CONFIGURED]"
  end

  # Reset memoization; used by specs that stub the environment.
  def self.reset_legal!
    @legal = nil
  end
end
