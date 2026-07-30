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

  validates :domain, presence: true, uniqueness: { scope: :account_id },
                     format: { with: /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/,
                               message: "must be a bare hostname like example.com" }
  validates :public_token, presence: true, uniqueness: true, length: { is: TOKEN_LENGTH }
  validates :k_anonymity_threshold, numericality: { in: 0..10_000 }
  validate  :timezone_is_recognised

  # The settings form edits this as one newline-separated textarea, because a
  # dynamic list widget is a lot of JavaScript for a field most sites never touch.
  def extra_hostnames_list
    extra_hostnames.to_a.join("\n")
  end

  def extra_hostnames_list=(value)
    self.extra_hostnames = value.to_s.split(/[\s,]+/).map { |h| normalize_hostname(h) }.compact_blank.uniq
  end

  before_validation :normalize_domain
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

  private

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

  def timezone_is_recognised
    return if timezone.blank?
    return if ActiveSupport::TimeZone[timezone].present?

    errors.add(:timezone, "is not a recognised timezone")
  end
end
