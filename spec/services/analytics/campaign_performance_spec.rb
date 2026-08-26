require "rails_helper"

# The campaign grain, for one site or for many. What the examples are actually
# about is the two things that make it worth having its own service: it must
# never be assembled by adding link rows up, and it must answer for several
# sites in one query without ever adding anything ACROSS them.
RSpec.describe Analytics::CampaignPerformance do
  let(:site) { create(:site, :no_suppression, timezone: "Etc/UTC") }
  let(:period) { Analytics::Period.parse("30d", site: site) }

  def performance(periods = { site => period })
    described_class.call(periods: periods).value!
  end

  def tag(target, visitor:, campaign:, source: "newsletter", medium: "email", **attrs)
    create_event(target, visitor: visitor, utm_source: source, utm_medium: medium,
                         utm_campaign: campaign, at: 2.days.ago, **attrs)
  end

  it "answers nothing at all when asked about nothing" do
    result = performance({})

    expect(result.rows).to be_empty
  end

  # THE FIGURE THAT MAY NOT BE A SUM. One person follows the Discord link and
  # then the Facebook link: two links, two rows of one visitor each, and ONE
  # visitor on the campaign. Adding the rows would claim an audience larger than
  # the one that existed.
  it "counts a visitor who followed two of a campaign's links once" do
    campaign = create(:campaign, site: site, utm_campaign: "august")
    tag(site, visitor: "a", campaign: "august", source: "discord", medium: "social")
    tag(site, visitor: "a", campaign: "august", source: "facebook", medium: "social")

    expect(performance.for_campaign(campaign).visitors).to eq(1)
  end

  it "counts visitors, visits and pageviews at their own grains" do
    campaign = create(:campaign, site: site, utm_campaign: "august")
    tag(site, visitor: "a", session: "s1", campaign: "august")
    tag(site, visitor: "a", session: "s1", campaign: "august")
    tag(site, visitor: "a", session: "s2", campaign: "august")
    tag(site, visitor: "b", session: "s3", campaign: "august")

    total = performance.for_campaign(campaign)

    expect([total.visitors, total.visits, total.pageviews]).to eq([2, 3, 4])
  end

  # Without the "carries a tag at all" condition the largest row by a wide
  # margin is the NULL one — every untagged visit the site had.
  it "ignores untagged traffic entirely" do
    create_event(site, visitor: "untagged", at: 2.days.ago)
    tag(site, visitor: "a", campaign: "august")

    expect(performance.rows.map(&:utm_campaign)).to eq(["august"])
  end

  it "is nil for a campaign nothing has arrived on" do
    campaign = create(:campaign, site: site, utm_campaign: "quiet")

    expect(performance.for_campaign(campaign)).to be_nil
  end

  # MANY SITES, ONE QUERY, AND NO ADDITION ACROSS THEM. Each site keeps its own
  # row; there is deliberately no total on the Result for anyone to reach for.
  describe "several sites at once" do
    let(:other) { create(:site, :no_suppression, timezone: "Etc/UTC", domain: "other.example.com") }
    let(:other_period) { Analytics::Period.parse("30d", site: other) }

    it "keeps one site's campaign apart from another's, even under the same tag" do
      mine = create(:campaign, site: site, utm_campaign: "august")
      theirs = create(:campaign, site: other, utm_campaign: "august")

      tag(site, visitor: "a", campaign: "august")
      tag(other, visitor: "b", campaign: "august")
      tag(other, visitor: "c", campaign: "august")

      result = performance({ site => period, other => other_period })

      expect(result.for_campaign(mine).visitors).to eq(1)
      expect(result.for_campaign(theirs).visitors).to eq(2)
    end

    # Each site brings its own window, OR'd into one WHERE clause. An event
    # inside one site's period and outside the other's must be admitted for the
    # first and refused for the second — which is the whole reason the windows
    # are per site rather than one range applied to everybody.
    it "measures each site over its own window" do
      recent = create(:campaign, site: site, utm_campaign: "recent")
      old = create(:campaign, site: other, utm_campaign: "old")

      create_event(site, visitor: "a", utm_source: "x", utm_medium: "y",
                         utm_campaign: "recent", at: 2.days.ago)
      create_event(other, visitor: "b", utm_source: "x", utm_medium: "y",
                          utm_campaign: "old", at: 20.days.ago)

      result = performance({ site => Analytics::Period.parse("7d", site: site),
                             other => Analytics::Period.parse("30d", site: other) })

      expect(result.for_campaign(recent).visitors).to eq(1)
      expect(result.for_campaign(old).visitors).to eq(1)

      narrow = performance({ site => Analytics::Period.parse("7d", site: site),
                             other => Analytics::Period.parse("7d", site: other) })

      expect(narrow.for_campaign(old)).to be_nil
    end
  end

  # PARTITIONED PER SITE, ON THAT SITE'S OWN THRESHOLD. It is a per-site
  # setting, so one partition across every site would apply one customer's rule
  # to another customer's visitors.
  describe "suppression" do
    let(:strict) { create(:site, timezone: "Etc/UTC", k_anonymity_threshold: 5) }
    let(:strict_period) { Analytics::Period.parse("30d", site: strict) }

    it "withholds a campaign seen by fewer visitors than the site's threshold" do
      campaign = create(:campaign, site: strict, utm_campaign: "august")
      2.times { |i| tag(strict, visitor: "v#{i}", campaign: "august") }

      result = performance({ strict => strict_period })

      expect(result.for_campaign(campaign)).to be_nil
      expect(result.withheld_for(strict)).to eq(1)
    end

    it "leaves a campaign above the threshold alone" do
      campaign = create(:campaign, site: strict, utm_campaign: "august")
      6.times { |i| tag(strict, visitor: "v#{i}", campaign: "august") }

      result = performance({ strict => strict_period })

      expect(result.for_campaign(campaign).visitors).to eq(6)
      expect(result).not_to be_withheld
    end

    # A strict site's rule must not reach across into a permissive one's rows,
    # which is exactly what a single partition over the combined result set
    # would do.
    it "applies each site's own threshold and not its neighbour's" do
      loose = create(:campaign, site: site, utm_campaign: "loose")
      tight = create(:campaign, site: strict, utm_campaign: "tight")

      tag(site, visitor: "a", campaign: "loose")
      tag(strict, visitor: "b", campaign: "tight")

      result = performance({ site => period, strict => strict_period })

      expect(result.for_campaign(loose).visitors).to eq(1)
      expect(result.for_campaign(tight)).to be_nil
    end
  end
end
