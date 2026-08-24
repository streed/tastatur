# A campaign is a name and a tag. The links under it are how it was distributed.
#
# WHY THE TAG IS THE GROUPING. Every link under a campaign carries this row's
# `utm_campaign`, which is what makes "what did August launch do" answerable at
# all: it is one GROUP BY over the events that carry that value, counted once.
# A campaign that were only a folder — each link keeping its own tag — could
# offer no such figure. The only total available would be the sum of its links'
# visitor counts, and one person who clicks the Discord link and then the
# Facebook one is two rows and one visitor, so that sum is larger than the
# audience it claims to describe. §8 forbids the same addition one grain down,
# for the same reason, and it is no more allowed here.
#
# So the tag is owned here and copied onto each link (see CampaignLink), not
# asked for per link.
class Campaign < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  MAX_NAME = 120
  MAX_VALUE = Ingest::PathScrubber::MAX_PARAM_LENGTH

  belongs_to :site
  # A campaign with no links is a heading with nothing under it, and deleting
  # one is deleting the thing the links were part of. The events keep their UTM
  # values either way — nothing measured is destroyed, which is what the screen
  # says when it offers this.
  has_many :campaign_links, dependent: :destroy

  accepts_nested_attributes_for :campaign_links, allow_destroy: true,
                                                 reject_if: :link_is_entirely_blank?

  validates :name, presence: true, length: { maximum: MAX_NAME },
                   uniqueness: { scope: :site_id, case_sensitive: false }
  validates :utm_campaign, presence: true, length: { maximum: MAX_VALUE },
                           uniqueness: { scope: :site_id }
  validate :tag_survives_the_scrubber

  scope :ordered, -> { order(created_at: :desc) }

  before_validation :derive_tag_from_name
  before_validation :normalize_tag

  # RENAMING THE TAG HAS TO MOVE THE LINKS WITH IT, in the same transaction.
  #
  # CampaignLink copies the tag down on every save, so without this the links
  # would keep the old spelling until each happened to be edited — and in the
  # meantime the heading would group by the new value while its own links
  # measured the old one. That is precisely the split campaign this feature
  # exists to make visible, produced by the feature itself.
  #
  # `update_all` rather than saving each link: the value has already been
  # validated here, this is a copy rather than a decision, and one statement
  # cannot leave half the links re-pointed if it fails.
  after_update :retag_links, if: :saved_change_to_utm_campaign?

  # What a link needs in order to be tagged. One place, so a link can never be
  # built against a spelling of the campaign the report will not match.
  def tag = utm_campaign

  private

  def retag_links
    campaign_links.update_all(utm_campaign: utm_campaign, updated_at: Time.current)
  end

  # TYPED ONCE, NOT TWICE. Somebody naming a campaign "August launch" means the
  # tag to be august-launch, and asking for both is asking the same question in
  # two vocabularies. The field stays editable — a tag already in use in an ad
  # platform has to be matched exactly — but it fills itself in.
  def derive_tag_from_name
    return if utm_campaign.present?

    self.utm_campaign = name.to_s.parameterize
  end

  # Lower-cased and squished, like every UTM value in this codebase: the match
  # is exact and case-sensitive, so `Newsletter` beside `newsletter` is two
  # campaigns and the traffic of one is split across both.
  def normalize_tag
    self.utm_campaign = utm_campaign.to_s.squish.downcase.presence
  end

  # The rule that would otherwise apply silently, months later, to somebody
  # else's click. A tag the scrubber discards on arrival makes every link under
  # this campaign report nothing at all, which on screen is indistinguishable
  # from a campaign nobody clicked. Checked against the same predicate the
  # ingest path calls, never a second copy of the regexes — see CLAUDE.md §12.
  def tag_survives_the_scrubber
    return if utm_campaign.blank?
    return if Ingest::PathScrubber.storable_param_value?(utm_campaign)

    errors.add(:utm_campaign, tag_message)
  end

  def tag_message
    if utm_campaign.include?("@")
      "cannot contain @ — a value that looks like an email address is discarded on arrival, " \
        "so every link in this campaign would report nothing."
    else
      "reads as a token rather than a name, so it is discarded on arrival and every link in " \
        "this campaign would report nothing. Break it up with a space or a slash, or shorten " \
        "it below #{MAX_VALUE} characters."
    end
  end

  # An untouched extra row on the builder is not a link somebody meant to make.
  # `destination_url` is excluded from the test on purpose: the form pre-fills
  # it with the site's own root, so a row carrying only that is still blank.
  def link_is_entirely_blank?(attributes)
    %w[name utm_source utm_medium utm_term utm_content].all? { |key| attributes[key].blank? }
  end
end
