# A tagged URL somebody built here, and the thing its performance row is
# matched against.
#
# The whole point of storing these rather than shipping a stateless builder
# widget is that a campaign is measured by STRING EQUALITY, months after the
# link was written, against a value a browser sent us. `Newsletter` and
# `newsletter` are two campaigns; `google` and `Google` are two sources. Nothing
# raises, and the report shows the campaign that worked splitting its traffic
# across two rows — the same failure Revenue::Channel exists to prevent one
# pipeline over.
#
# So the builder saves what it built, offers those values back on the next link
# (Analytics::CampaignValues), and refuses the two ways a link can be born dead:
# a destination this site does not measure, and a value Ingest::PathScrubber
# will drop on arrival.
class CampaignLink < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  # Source, medium and campaign are required; term and content are not.
  #
  # That is not a UTM-spec rule, it is this table's join key. A row identified by
  # a mostly-empty tuple collides with every other mostly-empty tuple, and the
  # three required ones are what makes "which campaign" answerable at all.
  # Term and content subdivide a campaign and are genuinely optional.
  REQUIRED_PARAMS = %i[utm_source utm_medium utm_campaign].freeze
  OPTIONAL_PARAMS = %i[utm_term utm_content].freeze
  PARAMS = (REQUIRED_PARAMS + OPTIONAL_PARAMS).freeze

  # Offered on the medium field, not enforced on it. These are the conventional
  # spellings — the value of a convention is that everyone uses the same one —
  # but a medium nobody anticipated is still a medium, and a <select> here would
  # make this product refuse to measure a channel it had not heard of.
  COMMON_MEDIUMS = %w[email social cpc display affiliate referral banner qr print].freeze

  MAX_VALUE = Ingest::PathScrubber::MAX_PARAM_LENGTH

  belongs_to :site

  validates :name, presence: true, uniqueness: { scope: :site_id }, length: { maximum: 120 }
  validates :destination_url, presence: true, length: { maximum: 2000 }
  validates(*REQUIRED_PARAMS, presence: true)
  validates(*PARAMS, length: { maximum: MAX_VALUE })

  validate :destination_is_a_page_on_this_site
  validate :params_survive_the_scrubber
  validate :tuple_is_not_already_taken

  scope :ordered, -> { order(utm_campaign: :asc, created_at: :desc) }

  before_validation :normalize_destination
  before_validation :normalize_params

  # The tagged URL. Built rather than stored — see the migration.
  #
  # Existing query parameters and the fragment both survive, and the fragment
  # has to end up last or the UTM values land inside it and are never sent.
  # `URI` puts them in that order for us, which is the reason this goes through
  # it instead of appending strings.
  def url
    uri = parsed_destination
    return destination_url.to_s if uri.nil?

    # "https://example.com?utm_source=x" is a legal URL and an odd thing to hand
    # somebody. The root path is what they meant.
    uri.path = "/" if uri.path.blank?

    existing = begin
      URI.decode_www_form(uri.query.to_s)
    rescue ArgumentError
      []
    end

    # Ours win: a destination that already carried `utm_source` was pasted from
    # somewhere, and the fields on the form are what the person is looking at.
    pairs = existing.reject { |key, _| PARAMS.include?(key.to_sym) } + utm_pairs

    # nil, not "". An empty query string still renders a trailing "?", which the
    # blank builder form would show as the destination the moment somebody
    # started typing it — and `new URL(...).toString()` in the live preview does
    # not add one, so the two halves would disagree on the very first keystroke.
    uri.query = pairs.any? ? URI.encode_www_form(pairs) : nil
    uri.to_s
  end

  # The five values as the report sees them: blank is NULL in the events table,
  # so it has to be nil here too or a link with no term matches nothing.
  def utm_key
    PARAMS.map { |param| public_send(param).presence }
  end

  def utm_pairs
    PARAMS.filter_map { |param| [param.to_s, public_send(param)] if public_send(param).present? }
  end

  private

  def parsed_destination
    URI.parse(destination_url.to_s)
  rescue URI::InvalidURIError
    nil
  end

  # A link to somewhere this site does not measure is not a campaign link, it is
  # a URL. It would be built, copied, sent to a mailing list and report nothing,
  # and the reason would be four screens away in the hostname policy.
  #
  # Checked against Ingest::HostnamePolicy rather than against `domain`, so the
  # answer here is the same one the ingest endpoint will give: extra hostnames
  # and subdomains are fine, and a site with enforcement switched off is not
  # nagged about a rule it is not applying.
  def destination_is_a_page_on_this_site
    return if destination_url.blank?

    uri = parsed_destination

    if uri.nil? || !uri.is_a?(URI::HTTP) || uri.host.blank?
      errors.add(:destination_url, "must be a full URL, like https://#{site&.domain || 'example.com'}/pricing")
      return
    end

    return if site.nil?

    result = Ingest::HostnamePolicy.new(site: site, url_host: uri.host).call
    return if result.allowed?

    errors.add(:destination_url,
               "points at #{uri.host}, which this site does not measure. " \
               "Traffic to it would never appear in this report.")
  end

  # The rule that would otherwise apply silently, months later, to somebody
  # else's click. See Ingest::PathScrubber#storable_param_value?.
  def params_survive_the_scrubber
    PARAMS.each do |param|
      value = public_send(param)
      next if value.blank?
      next if Ingest::PathScrubber.storable_param_value?(value)

      errors.add(param, scrubber_message(value))
    end
  end

  def scrubber_message(value)
    if value.include?("@")
      "cannot contain @ — a value that looks like an email address is discarded on arrival, " \
        "so this link would report nothing."
    else
      "reads as a token rather than a name, so it is discarded on arrival and this link would " \
        "report nothing. Break it up with a space or a slash, or shorten it below 25 characters."
    end
  end

  # The unique index is the guarantee; this is the sentence. Without it the
  # collision surfaces as RecordNotUnique — a 500 on a form somebody filled in
  # correctly by every rule they had been shown.
  def tuple_is_not_already_taken
    return if site.nil? || REQUIRED_PARAMS.any? { |param| public_send(param).blank? }

    clash = site.campaign_links.where(**PARAMS.index_with { |param| public_send(param).presence })
    clash = clash.where.not(id: id) if persisted?
    other = clash.first
    return if other.nil?

    errors.add(:base,
               "“#{other.name}” already uses these exact values, so the two links could not be " \
               "told apart in the report. Give this one a different utm_content.")
  end

  def normalize_destination
    self.destination_url = destination_url.to_s.strip.presence
  end

  # Lower-cased, because the comparison this feeds is case-sensitive and
  # "Google" arriving next to "google" is the split-campaign bug this class is
  # about. Whitespace collapses for the same reason — a trailing space is
  # invisible on the form and is a different string in the database.
  #
  # NOT the destination URL: a path is case-sensitive on most servers and
  # lower-casing one would break the link itself.
  def normalize_params
    PARAMS.each do |param|
      value = public_send(param).to_s.squish.downcase.presence
      public_send(:"#{param}=", value)
    end
  end
end
