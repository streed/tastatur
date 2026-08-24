require "rails_helper"

# The point of saving a built link rather than shipping a stateless widget is
# that the value written here is the value Analytics::CampaignReport matches on
# months later. Every example below is about one of the ways that match could
# silently fail to happen.
RSpec.describe CampaignLink do
  let(:site) { create(:site, domain: "northwind.example.com") }

  # The tag belongs to the campaign now, so a link that needs a particular one
  # gets a campaign carrying it. Setting `utm_campaign` on the link itself would
  # be silently overwritten by CampaignLink#adopt_campaign_tag, and an example
  # that appeared to be about the link would in fact be about the campaign.
  def link_tagged(tag, **attrs)
    build(:campaign_link, campaign: create(:campaign, site: site, utm_campaign: tag), **attrs)
  end

  describe "the built URL" do
    it "tags the destination with the values that are filled in and no others" do
      link = link_tagged("august", destination_url: "https://northwind.example.com/pricing",
                                   utm_source: "newsletter", utm_medium: "email",
                                   utm_term: nil, utm_content: nil)

      expect(link.url).to eq(
        "https://northwind.example.com/pricing?utm_source=newsletter&utm_medium=email&utm_campaign=august"
      )
    end

    it "keeps the destination's own query parameters" do
      link = build(:campaign_link, site: site,
                                   destination_url: "https://northwind.example.com/pricing?plan=pro")

      expect(link.url).to start_with("https://northwind.example.com/pricing?plan=pro&utm_source=")
    end

    # A UTM value written after the "#" is never sent to the server, so a
    # builder that appended blindly would produce links that measure nothing.
    it "leaves the fragment at the end, after the parameters it adds" do
      link = build(:campaign_link, site: site,
                                   destination_url: "https://northwind.example.com/docs#install")

      expect(link.url).to end_with("#install")
      expect(link.url).to include("utm_source=newsletter")
    end

    it "overwrites a utm value the destination already carried" do
      link = build(:campaign_link, site: site, utm_source: "newsletter",
                                   destination_url: "https://northwind.example.com/?utm_source=stale")

      expect(link.url).to include("utm_source=newsletter")
      expect(link.url).not_to include("stale")
    end

    # The blank builder form renders this before anything is typed, and the
    # JavaScript preview that takes over from it does not emit a trailing "?".
    it "adds no query string at all when nothing is tagged" do
      link = CampaignLink.new(site: site, destination_url: "https://northwind.example.com/pricing")

      expect(link.url).to eq("https://northwind.example.com/pricing")
    end

    it "gives a bare origin a path rather than hanging the query off nothing" do
      link = build(:campaign_link, site: site, destination_url: "https://northwind.example.com")

      expect(link.url).to start_with("https://northwind.example.com/?")
    end
  end

  describe "values that would be discarded on arrival" do
    # Ingest::PathScrubber drops a utm value that reads as a token, because
    # mailing platforms put per-recipient hashes in utm_content. A link carrying
    # one saves cleanly and then reports nothing forever, which on screen is
    # indistinguishable from a campaign nobody clicked.
    it "refuses a token-shaped term" do
      link = build(:campaign_link, site: site, utm_term: "a" * 30)

      expect(link).not_to be_valid
      expect(link.errors[:utm_term].join).to include("discarded on arrival")
    end

    it "refuses a value containing an email address" do
      link = build(:campaign_link, site: site, utm_content: "alice@example.com")

      expect(link).not_to be_valid
      expect(link.errors[:utm_content].join).to include("@")
    end

    it "accepts a long term broken up by a space" do
      link = build(:campaign_link, site: site, utm_term: "august launch newsletter blast")

      expect(link).to be_valid
    end

    # The one test that would catch the two rules drifting apart. If the model
    # ever grows its own copy of the regexes, this is what fails.
    it "agrees with the scrubber it is standing in for" do
      value = "b" * 30

      expect(Ingest::PathScrubber.storable_param_value?(value)).to be(false)
      expect(build(:campaign_link, site: site, utm_term: value)).not_to be_valid
    end
  end

  describe "the destination" do
    it "refuses a host this site does not measure" do
      link = build(:campaign_link, site: site, destination_url: "https://elsewhere.example.org/")

      expect(link).not_to be_valid
      expect(link.errors[:destination_url].join).to include("elsewhere.example.org")
    end

    it "accepts a subdomain, which the hostname policy accepts too" do
      expect(build(:campaign_link, site: site, destination_url: "https://blog.northwind.example.com/x"))
        .to be_valid
    end

    it "refuses something that is not a URL at all" do
      link = build(:campaign_link, site: site, destination_url: "/pricing")

      expect(link).not_to be_valid
    end
  end

  describe "normalisation" do
    # `Newsletter` and `newsletter` are two rows in the report, forever. This is
    # the whole reason the values are stored rather than concatenated.
    it "lower-cases and squishes the tag values, but not the destination" do
      link = create(:campaign_link, campaign: create(:campaign, site: site, utm_campaign: "August   Launch"),
                                    utm_source: "  NewsLetter ",
                                    destination_url: "https://northwind.example.com/Pricing")

      expect(link.utm_source).to eq("newsletter")
      # Copied down from the campaign, which normalised it there. The link is
      # not a second place the value can be spelled.
      expect(link.utm_campaign).to eq("august launch")
      expect(link.destination_url).to eq("https://northwind.example.com/Pricing")
    end
  end

  describe "two links with the same tags" do
    # They would be one row in the report and two rows on the screen, each
    # claiming all of it — so the same visitors are shown twice and the screen
    # implies double the traffic the site had.
    it "is refused with a sentence rather than a RecordNotUnique" do
      august = create(:campaign, site: site, utm_campaign: "august")
      create(:campaign_link, campaign: august, name: "First", utm_source: "newsletter",
                             utm_medium: "email")

      second = build(:campaign_link, campaign: august, name: "Second", utm_source: "newsletter",
                                     utm_medium: "email")

      expect(second).not_to be_valid
      expect(second.errors[:base].join).to include("utm_content")
    end

    it "allows the same campaign on two links told apart by utm_content" do
      august = create(:campaign, site: site, utm_campaign: "august")
      create(:campaign_link, campaign: august, name: "Header", utm_content: "header")

      expect(build(:campaign_link, campaign: august, name: "Footer",
                                   utm_content: "footer")).to be_valid
    end
  end

  describe "#utm_key" do
    # Blank has to become nil, because the events table stores NULL for a tag
    # that was not present and "" is not NULL in any comparison.
    it "reports absent tags as nil so it can match a row with NULL columns" do
      link = link_tagged("august", utm_source: "newsletter", utm_medium: "email",
                                   utm_term: "", utm_content: nil)

      expect(link.utm_key).to eq(["newsletter", "email", "august", nil, nil])
    end
  end
end
