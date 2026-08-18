require "rails_helper"

RSpec.describe Analytics::CampaignReport do
  # Suppression has its own examples at the bottom; everything else is about
  # what the tuple grouping does, so most of this runs with the threshold off.
  let(:site) { create(:site, :no_suppression, timezone: "Etc/UTC") }
  let(:period) { Analytics::Period.parse("30d", site: site) }

  def report = described_class.call(site: site, period: period).value!

  def tag(visitor:, campaign:, source: "newsletter", medium: "email", **attrs)
    create_event(site, visitor: visitor, utm_source: source, utm_medium: medium,
                       utm_campaign: campaign, at: 2.days.ago, **attrs)
  end

  it "groups by all five values, not by the campaign name alone" do
    tag(visitor: "a", campaign: "august", utm_content: "header")
    tag(visitor: "b", campaign: "august", utm_content: "footer")

    expect(report.rows.map(&:utm_content)).to contain_exactly("header", "footer")
  end

  # The reason this service exists rather than a Breakdown call. Grouping by
  # utm_campaign alone gives the email, the tweet and the banner one row and one
  # figure, which is the number already on the dashboard.
  it "keeps two links of one campaign apart" do
    tag(visitor: "a", campaign: "august", source: "twitter", medium: "social")
    tag(visitor: "b", campaign: "august", source: "newsletter", medium: "email")

    expect(report.rows.size).to eq(2)
  end

  it "counts visitors, visits and pageviews at their own grains" do
    tag(visitor: "a", session: "s1", campaign: "august")
    tag(visitor: "a", session: "s1", campaign: "august")
    tag(visitor: "a", session: "s2", campaign: "august")
    tag(visitor: "b", session: "s3", campaign: "august")

    row = report.rows.first

    expect([row.visitors, row.visits, row.pageviews]).to eq([2, 3, 4])
  end

  # Without the "has any tag at all" condition the biggest row by far is five
  # NULLs — every untagged visit the site had, which is every other report in
  # the product and nothing to do with a campaign.
  it "ignores untagged traffic entirely" do
    create_event(site, visitor: "untagged", at: 2.days.ago)
    tag(visitor: "a", campaign: "august")

    expect(report.rows.size).to eq(1)
  end

  it "matches a saved link to its row, including on the tags it left blank" do
    tag(visitor: "a", campaign: "august")
    link = create(:campaign_link, site: site, utm_source: "newsletter", utm_medium: "email",
                                  utm_campaign: "august", utm_term: nil, utm_content: nil)

    expect(report.for_link(link)&.visitors).to eq(1)
  end

  it "does not match a link whose spelling differs by case" do
    tag(visitor: "a", campaign: "August")
    link = create(:campaign_link, site: site, utm_campaign: "august")

    expect(report.for_link(link)).to be_nil
  end

  it "leaves an event outside the period out" do
    create_event(site, visitor: "old", utm_campaign: "spring", utm_source: "x", utm_medium: "y",
                       at: 90.days.ago)

    expect(report.rows).to be_empty
  end

  describe "the privacy threshold" do
    let(:site) { create(:site, k_anonymity_threshold: 5, timezone: "Etc/UTC") }

    it "withholds a row seen by too few visitors and says how many it withheld" do
      6.times { |i| tag(visitor: "big-#{i}", campaign: "august") }
      tag(visitor: "solo", campaign: "private-beta")
      tag(visitor: "pair-1", campaign: "friends-and-family")
      tag(visitor: "pair-2", campaign: "friends-and-family")

      expect(report.rows.map(&:utm_campaign)).to eq(["august"])
      expect(report.suppressed_rows).to eq(2)
    end

    # Complementary suppression, inherited from Analytics::Suppression and
    # asserted here because it is startling on this screen specifically: build
    # one link that works and one that nobody clicks, and BOTH disappear. With a
    # single row withheld its visitor count is the reported total minus the
    # visible rows, so hiding it alone would protect nothing.
    it "withholds a second row when only one fell below, so neither can be derived" do
      6.times { |i| tag(visitor: "big-#{i}", campaign: "august") }
      tag(visitor: "solo", campaign: "private-beta")

      expect(report.rows).to be_empty
      expect(report.suppressed_rows).to eq(2)
    end

    # A link the owner built is still a row about visitors. Complementary
    # suppression means the withheld row cannot be recovered from what is shown.
    it "leaves a saved link unmatched when its row was withheld" do
      tag(visitor: "solo", campaign: "august")
      link = create(:campaign_link, site: site, utm_campaign: "august")

      expect(report.for_link(link)).to be_nil
    end
  end
end
