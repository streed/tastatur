require "rails_helper"

# A campaign is a name and a tag, and the tag is the thing that makes the
# grouping real: every link under it carries that value, so "what did August
# launch do" is one GROUP BY over the events that carry it rather than a sum of
# rows that would double-count anybody who followed two links.
#
# Every example below is about one of the ways that could quietly stop being
# true.
RSpec.describe Campaign do
  let(:site) { create(:site, domain: "northwind.example.com") }

  describe "the tag" do
    # Typed once. Somebody naming a campaign "August launch" means the tag to be
    # august-launch, and asking for both is asking the same question twice.
    it "is made from the name when none is given" do
      campaign = create(:campaign, site: site, name: "August Launch", utm_campaign: nil)

      expect(campaign.utm_campaign).to eq("august-launch")
    end

    # A campaign already running in an ad platform has a tag that has to be
    # matched exactly, and the derived one would be wrong.
    it "keeps one that was given rather than overwriting it from the name" do
      campaign = create(:campaign, site: site, name: "August Launch", utm_campaign: "aug25")

      expect(campaign.utm_campaign).to eq("aug25")
    end

    # `Newsletter` beside `newsletter` is two campaigns and the traffic of one
    # split across both — the failure this whole feature exists to make visible.
    it "is lower-cased and squished" do
      campaign = create(:campaign, site: site, utm_campaign: "  August   Launch ")

      expect(campaign.utm_campaign).to eq("august launch")
    end

    # Two campaigns on one tag would each group the same events and each claim
    # all of them: the same visitors shown twice under two headings.
    it "cannot be used by two campaigns on one site" do
      create(:campaign, site: site, utm_campaign: "august")

      expect(build(:campaign, site: site, utm_campaign: "august")).not_to be_valid
    end

    it "may be used by campaigns on different sites" do
      create(:campaign, site: site, utm_campaign: "august")

      expect(build(:campaign, site: create(:site), utm_campaign: "august")).to be_valid
    end
  end

  # Ingest::PathScrubber drops a utm value that reads as a token, because
  # mailing platforms put per-recipient hashes in them. A campaign carrying one
  # saves cleanly and then every link under it reports nothing forever, which on
  # screen is indistinguishable from a campaign nobody clicked. This is the
  # check that used to live on the link, and it matters more here: one bad tag
  # now kills every link in the group rather than one of them.
  describe "a tag the scrubber would discard" do
    it "is refused, naming the consequence for the whole campaign" do
      campaign = build(:campaign, site: site, utm_campaign: "a" * 30)

      expect(campaign).not_to be_valid
      expect(campaign.errors[:utm_campaign].join).to include("every link in this campaign")
    end

    it "is accepted when broken up by a space, which survives the scrubber" do
      expect(build(:campaign, site: site, utm_campaign: "august launch newsletter blast")).to be_valid
    end

    # The test that would catch the two rules drifting apart. If this model ever
    # grows its own copy of the regexes, this is what fails.
    it "agrees with the scrubber it is standing in for" do
      value = "b" * 30

      expect(Ingest::PathScrubber.storable_param_value?(value)).to be(false)
      expect(build(:campaign, site: site, utm_campaign: value)).not_to be_valid
    end
  end

  describe "renaming the tag" do
    # IMMEDIATELY, not on each link's next save. The links carry the tag as a
    # denormalised copy, so a rename that did not move them would leave the
    # heading grouping by the new value while its own links still measured the
    # old one — the split campaign this feature exists to catch, manufactured by
    # the feature itself.
    it "re-points every link under it at once" do
      campaign = create(:campaign, site: site, utm_campaign: "august")
      link = create(:campaign_link, campaign: campaign)

      campaign.update!(utm_campaign: "september")

      expect(link.reload.utm_campaign).to eq("september")
    end

    it "leaves the links alone when something other than the tag changes" do
      campaign = create(:campaign, site: site, utm_campaign: "august")
      link = create(:campaign_link, campaign: campaign)

      expect { campaign.update!(name: "Renamed") }.not_to(change { link.reload.updated_at })
    end
  end

  describe "deleting one" do
    it "takes its links with it" do
      campaign = create(:campaign, site: site)
      create(:campaign_link, campaign: campaign)

      expect { campaign.destroy! }.to change(CampaignLink, :count).by(-1)
    end
  end

  describe "nested links" do
    # The builder ships with one blank row and an Add button, so a campaign
    # created with the row untouched must be a campaign rather than a validation
    # failure about a link nobody was trying to make.
    it "ignores a row nothing was typed into" do
      campaign = Campaign.new(site: site, name: "August",
                              campaign_links_attributes: [{ destination_url: "https://northwind.example.com/" }])

      expect(campaign).to be_valid
      expect(campaign.campaign_links).to be_empty
    end

    it "builds the links that were filled in, tagged with the campaign's own value" do
      campaign = Campaign.create!(site: site, name: "August", utm_campaign: "august",
                                  campaign_links_attributes: [
                                    { name: "Discord", destination_url: "https://northwind.example.com/",
                                      utm_source: "discord", utm_medium: "social" },
                                    { name: "Facebook", destination_url: "https://northwind.example.com/",
                                      utm_source: "facebook", utm_medium: "social" }
                                  ])

      expect(campaign.campaign_links.map(&:name)).to contain_exactly("Discord", "Facebook")
      expect(campaign.campaign_links.map(&:utm_campaign).uniq).to eq(["august"])
      expect(campaign.campaign_links.map(&:site_id).uniq).to eq([site.id])
    end
  end
end
