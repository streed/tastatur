class Site < ApplicationRecord
  include PubliclyIdentified
  public_identifier :public_token

  # Crockford-style base32: no I, L, O or U, so a token read off a screen and
  # typed back in cannot be garbled and cannot accidentally spell a word.
  TOKEN_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ".chars.freeze
  TOKEN_LENGTH = 16

  belongs_to :account
  has_many :goals, dependent: :destroy
  has_many :funnels, dependent: :destroy
  has_many :shared_links, dependent: :destroy
  has_many :dashboards, dependent: :destroy

  # --- The revenue side ------------------------------------------------------
  # All :destroy rather than :delete_all, because Customer and CustomerSubscription
  # each own rows below them. `dependent: :delete_all` here would leave orphaned
  # revenue_events pointing at a customer_id that no longer exists — and the
  # foreign key would refuse the delete, so deleting a site would 500 instead.
  has_many :api_keys, dependent: :destroy
  has_many :customers, dependent: :destroy
  has_many :customer_subscriptions, dependent: :destroy
  has_many :revenue_events, dependent: :destroy
  has_many :connect_events, dependent: :destroy
  has_many :stripe_connections, dependent: :destroy
  has_many :attribution_rollups, dependent: :delete_all

  # One rule for every hostname this model holds, because they all end up in the
  # same place — Ingest::HostnamePolicy#candidates concatenates `domain` and
  # `extra_hostnames` and treats them identically. A rule enforced on one and not
  # the other is not a rule: the value refused in the Domain field was accepted
  # verbatim one field lower, and the policy could not tell which box it came from.
  HOSTNAME_FORMAT = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/
  HOSTNAME_MESSAGE = "must be a bare hostname like example.com".freeze

  # Why an overlap is refused rather than tolerated, in the words of the person it
  # happens to. The long version is on #hostnames_are_not_claimed_by_a_sibling.
  CLAIM_CONSEQUENCE = "Sharing it means a page carrying the wrong site's snippet " \
                      "is accepted instead of refused, so the mistake stops showing up.".freeze

  validates :domain, presence: true, uniqueness: { scope: :account_id },
                     format: { with: HOSTNAME_FORMAT, message: HOSTNAME_MESSAGE }
  validates :public_token, presence: true, uniqueness: true, length: { is: TOKEN_LENGTH }
  validates :k_anonymity_threshold, numericality: { in: 0..10_000 }
  validates :base_currency, format: { with: /\A[A-Z]{3}\z/, message: "must be a three-letter ISO code like USD" }
  validate  :timezone_is_recognised

  # `on: :create` ONLY, and that is not a detail.
  #
  # An account can legitimately hold more sites than its plan allows: cancelling
  # Pro drops you to Free with all twenty sites still collecting, because a billing
  # event must never delete a customer's data. An unscoped validation would then
  # make every one of those sites unsavable — changing a timezone or a
  # k-anonymity threshold would 422 with a message about site limits, which is
  # both baffling and unfixable without deleting nineteen sites.
  #
  # So the limit governs adding, never keeping. spec/requests/sites_spec.rb asserts
  # both halves.
  validate  :account_within_site_limit, on: :create

  # ALL THREE GOVERN CHANGING A HOSTNAME, NEVER KEEPING ONE — the same rule, and
  # for the same reason, as `account_within_site_limit` above.
  #
  # None of these existed until now, so rows predating them can hold values they
  # would refuse: `extra_hostnames_list=` normalised its input and never checked
  # it. Applied unconditionally, a site with one bad entry could not have its
  # timezone changed until that entry was fixed, and the overlap check is worse
  # still — it fires on the site you are NOT editing, so the remedy would live on
  # a different page than the refusal. Gated on the hostname actually changing,
  # nothing already saved can lock anyone out and nothing new can get in.
  #
  # The residual is deliberate and worth stating: an existing bad value stays
  # live until somebody edits that field.
  HOSTNAMES_CHANGED = -> { new_record? || domain_changed? || extra_hostnames_changed? }
  private_constant :HOSTNAMES_CHANGED

  validate :extra_hostnames_are_well_formed, if: HOSTNAMES_CHANGED
  validate :hostnames_are_not_public_suffixes, if: HOSTNAMES_CHANGED
  validate :hostnames_are_not_claimed_by_a_sibling, if: HOSTNAMES_CHANGED

  # The settings form edits this as one newline-separated textarea, because a
  # dynamic list widget is a lot of JavaScript for a field most sites never touch.
  def extra_hostnames_list
    extra_hostnames.to_a.join("\n")
  end

  def extra_hostnames_list=(value)
    self.extra_hostnames = value.to_s.split(/[\s,]+/).map { |h| normalize_hostname(h) }.compact_blank.uniq
  end

  before_validation :normalize_domain
  before_validation :normalize_base_currency
  before_validation :assign_public_token, on: :create

  scope :ordered, -> { order(:domain) }

  # Hostnames accepted in addition to the domain and its subdomains. For a site
  # genuinely served on separate domains, which no subdomain rule can infer.
  def allowed_hostnames
    ([domain] + extra_hostnames.to_a).compact_blank
  end

  def rejection_counts(since: 7.days.ago)
    Ingest::RejectionCounter.counts_for(self, since: since)
  end

  def rejected_hostnames(limit: 5)
    Ingest::RejectionCounter.top_hosts(self, limit: limit)
  end

  def receiving_data?
    first_event_at.present?
  end

  # Breakdown rows seen by fewer than this many distinct visitors are withheld.
  # A site that has explicitly set the threshold to 0 has opted out, which is
  # only offered because a site owner looking at their own low-traffic blog is
  # not a privacy risk to anyone.
  def suppress_small_rows?
    k_anonymity_threshold.positive?
  end

  def snippet
    %(<script defer data-site="#{public_token}" src="#{Tastatur.tracker_url}"></script>)
  end

  # The live Stripe connection, or nil. Memoized per instance because the
  # revenue screens ask several times per render.
  def stripe_connection
    return @stripe_connection if defined?(@stripe_connection)

    @stripe_connection = stripe_connections.live.first
  end

  def stripe_connected? = stripe_connection.present?

  private

  # Accepts "usd", " Usd " and stores "USD". The CHECK constraint refuses
  # anything else outright, and a 500 from a constraint is a worse way to learn
  # you typed lowercase than a validation message.
  def normalize_base_currency
    self.base_currency = base_currency.to_s.strip.upcase.presence || "USD"
  end

  # Accepts anything a user is likely to paste — "https://WWW.Example.com/",
  # "example.com:3000" — and stores the bare lowercase hostname that the
  # tracker will actually report.
  def normalize_domain
    return if domain.blank?

    value = domain.to_s.strip.downcase
    value = value.sub(%r{\Ahttps?://}, "")
    value = value.split("/").first.to_s
    value = value.split("?").first.to_s
    value = value.sub(/:\d+\z/, "")
    value = value.sub(/\Awww\./, "")
    self.domain = value.chomp(".")
  end

  def assign_public_token
    return if public_token.present?

    # 32^16 ≈ 1.2e24 possibilities. Even at a billion sites the probability of
    # a collision is negligible, but the uniqueness index is the real guard —
    # this loop just avoids surfacing a validation error for it.
    loop do
      candidate = Array.new(TOKEN_LENGTH) { TOKEN_ALPHABET.sample(random: SecureRandom) }.join
      next if Site.exists?(public_token: candidate)

      self.public_token = candidate
      break
    end
  end

  def normalize_hostname(host)
    host.to_s.strip.downcase.sub(%r{\Ahttps?://}, "").split("/").first.to_s
        .sub(/:\d+\z/, "").sub(/\Awww\./, "").chomp(".").presence
  end

  def extra_hostnames_are_well_formed
    bad = extra_hostnames.to_a.reject { |host| host.match?(HOSTNAME_FORMAT) }
    return if bad.empty?

    errors.add(:extra_hostnames_list, "#{HOSTNAME_MESSAGE.sub('must be', 'must each be')}. Check #{bad.to_sentence}.")
  end

  # A public suffix is not a site, and one in either field silently switches the
  # hostname policy off. `HostnamePolicy#permitted?` accepts `host == allowed` OR
  # anything ending in `.#{allowed}`, so an entry of `co.uk` accepts every
  # hostname in the United Kingdom — while the settings page goes on reporting
  # enforcement as on, and Site#rejected_hostnames stays reassuringly empty.
  # Protection that reads as present and is not is worse than none.
  #
  # `github.io` and `vercel.app` are the versions somebody actually types, because
  # that genuinely is where their site lives. The Public Suffix List is the only
  # thing that knows `co.uk` is a suffix and `co.uk.com` is not; a label count
  # cannot tell them apart.
  #
  # Only a BARE suffix is refused. `mysite.github.io` is a real site and passes.
  def hostnames_are_not_public_suffixes
    if suffix_only?(domain)
      errors.add(:domain, "is a public suffix, not a site. Use the hostname you actually serve, like mysite.#{domain}.")
    end

    bare = extra_hostnames.to_a.select { |host| suffix_only?(host) }
    return if bare.empty?

    errors.add(:extra_hostnames_list,
               "cannot contain a public suffix: #{bare.to_sentence}. " \
               "An entry like that accepts every hostname beneath it, which turns hostname checking off.")
  end

  # Well-formed and not registrable is exactly the bare-suffix case. Anything that
  # failed the format rule is somebody else's error to report.
  def suffix_only?(host)
    host.present? && host.match?(HOSTNAME_FORMAT) && !PublicSuffix.valid?(host)
  end

  # Two sites in one account accepting the same hostname does NOT double-count
  # anything: Ingest::SiteResolver resolves the site from the token in the
  # snippet, so each site still receives only what its own snippet sends.
  #
  # What an overlap costs is the signal. Paste site A's snippet onto a page of
  # site B and the hostname policy normally refuses it and records the host in
  # Site#rejected_hostnames — which is how that mistake gets noticed at all,
  # because the events are otherwise simply missing from a report nobody is
  # looking at yet. An overlap makes the wrong snippet acceptable to both sites,
  # so the events land on the wrong one and nothing is ever recorded as refused.
  # The misconfiguration becomes invisible in the exact place built to show it.
  #
  # Scoped to the account for the same reason `domain` uniqueness is: two
  # unrelated customers measuring the same host is legitimate and not ours to
  # arbitrate. Checked in both directions, since the overlap is symmetrical and
  # whichever field the person is editing is the one they can fix.
  def hostnames_are_not_claimed_by_a_sibling
    return if account_id.nil?
    return if errors.include?(:domain) || errors.include?(:extra_hostnames_list)

    mine = allowed_hostnames
    return if mine.empty?

    sibling = claiming_sibling(mine)
    return if sibling.nil?

    (mine & sibling.allowed_hostnames).each { |host| add_claim_error(host, sibling) }
  end

  # The GIN index on extra_hostnames serves the `&&` half; the account scope keeps
  # the other half to one customer's handful of rows.
  def claiming_sibling(hosts)
    account.sites
           .where.not(id: id)
           .where("domain = ANY (ARRAY[:hosts]::varchar[]) OR extra_hostnames && ARRAY[:hosts]::varchar[]",
                  hosts: hosts)
           .first
  end

  # Phrased to read after the attribute name that full_messages prepends, and
  # never circularly: "already measured by example.com" says nothing useful when
  # example.com is also the host being refused, which is the commonest case of
  # all. Which site holds the claim, and how, is what the reader needs.
  def add_claim_error(host, sibling)
    if host == domain
      errors.add(:domain, "is already an additional hostname on #{sibling.domain}. " \
                          "Remove it there, or measure this site on a hostname of its own.")
    elsif host == sibling.domain
      errors.add(:extra_hostnames_list,
                 "cannot include #{host}: it is already the domain of another site in this account. " \
                 "#{CLAIM_CONSEQUENCE}")
    else
      errors.add(:extra_hostnames_list,
                 "cannot include #{host}: the site #{sibling.domain} already lists it. #{CLAIM_CONSEQUENCE}")
    end
  end

  def timezone_is_recognised
    return if timezone.blank?
    return if ActiveSupport::TimeZone[timezone].present?

    errors.add(:timezone, "is not a recognised timezone")
  end

  # Derived from the account's plan, with no separate check for deployment mode:
  # a self-hosted install puts every account on Billing::Plan::SELF_HOSTED, whose
  # site_limit is UNLIMITED, so this never fires there. Two gates on the same fact
  # is how one of them ends up wrong.
  #
  # `errors.add(:base, ...)` rather than `:domain`, because nothing is wrong with
  # the domain they typed — the message belongs in the form's summary, where
  # TastaturFormBuilder#error_summary puts it.
  def account_within_site_limit
    return if account.nil?

    limit = account.site_limit
    return if limit == Billing::Plan::UNLIMITED
    return unless account.at_site_limit?

    errors.add(:base, "#{account.name} is limited to #{limit} #{'site'.pluralize(limit)}. #{limit_remedy}")
  end

  def limit_remedy
    pro = Billing::Plan.pro

    if account.can_upgrade?
      "Upgrade to #{pro.name} for #{pro.site_limit} sites, or delete a site you no longer measure."
    else
      "Delete a site you no longer measure, or get in touch about raising the limit."
    end
  end
end
