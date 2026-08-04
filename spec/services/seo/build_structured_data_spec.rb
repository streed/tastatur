require "rails_helper"

RSpec.describe Seo::BuildStructuredData do
  let(:url_options) { { protocol: "https://", host: "analytics.example.org" } }

  def graph_for(page)
    described_class.call(page: page, url_options: url_options).value!.graph
  end

  def node(page, type)
    graph_for(page).find { |n| n["@type"] == type }
  end

  before { allow(Tastatur).to receive(:billing_enabled?).and_return(true) }

  it "refuses a page it has nothing to say about, rather than emitting an empty graph" do
    expect { described_class.call(page: :sidekiq, url_options: url_options) }
      .to raise_error(ArgumentError, /known pages are/)
  end

  it "builds every URL on the host it was given" do
    urls = graph_for(:home).flat_map { |n| n.values_at("@id", "url") }.compact

    expect(urls).to all(start_with("https://analytics.example.org"))
  end

  # The whole point of a graph over sibling <script> blocks: the nodes reference
  # each other, so a consumer knows the FAQ and the docs belong to the same site
  # rather than being three unrelated documents that happen to share a host.
  it "puts every page under the same WebSite node" do
    website_id = node(:home, "WebSite")["@id"]

    expect(node(:docs, "TechArticle")["isPartOf"]).to eq("@id" => website_id)
  end

  describe "the software node" do
    subject(:software) { node(:home, "SoftwareApplication") }

    it "carries the fields a rich result is dropped for omitting" do
      expect(software).to include(
        "name" => "Tastatur",
        "applicationCategory" => "BusinessApplication",
        "operatingSystem" => "Any",
        "isAccessibleForFree" => true,
        "license" => "https://www.gnu.org/licenses/agpl-3.0.html"
      )
    end

    # AUTHORSHIP IS A FIXED FACT and operator identity is not — see the class
    # comment. Reedster LLC wrote every copy of this software, so it is the
    # author on every instance including somebody else's self-hosted one.
    it "names the maintainer as author on every deployment" do
      allow(Tastatur).to receive(:self_hosted?).and_return(true)

      expect(node(:home, "SoftwareApplication")["author"])
        .to include("name" => "Reedster LLC")
    end
  end

  describe "the operator organization" do
    it "is emitted once this instance has said who runs it" do
      allow(Tastatur).to receive(:legal_configured?).and_return(true)
      allow(Tastatur).to receive(:legal_value).with(:entity).and_return("Someone Else Ltd")

      expect(node(:home, "Organization")).to include("name" => "Someone Else Ltd")
    end

    # Name and URL, and nothing else. The operator's contact and postal
    # addresses are configured and are already on /privacy-policy in prose;
    # restating them in a machine-readable block served to every scraper that
    # asks is a harvesting convenience, not a disclosure the reader gains from.
    it "publishes who runs it, not how to write to them" do
      allow(Tastatur).to receive(:legal_configured?).and_return(true)
      allow(Tastatur).to receive(:legal_value).with(:entity).and_return("Someone Else Ltd")

      expect(node(:home, "Organization").keys).to contain_exactly("@type", "@id", "name", "url")
    end

    # A self-hosted install that never filled the variables in must not publish
    # OUR name as the operator of THEIR site. Same class of bug as a hardcoded
    # Sitemap: line in robots.txt — every copy advertising the original as
    # itself. The /privacy-policy page takes the same position for the same
    # reason: an unconfigured instance says so rather than inventing a name.
    it "is absent entirely where nobody has been named" do
      allow(Tastatur).to receive(:legal_configured?).and_return(false)

      expect(graph_for(:home).map { |n| n["@type"] }).not_to include("Organization")
    end
  end

  # The `offers` on a SoftwareApplication and the whole FAQPage node are
  # registered by an edition, and are asserted in the repository that registers
  # them. What belongs here is that the extension points exist and are used —
  # see the two examples at the end of this file.

  it "serialises to JSON that parses back to the same graph" do
    data = described_class.call(page: :home, url_options: url_options).value!

    round_tripped = JSON.parse(JSON.generate(data.to_json_ld))

    expect(round_tripped["@context"]).to eq("https://schema.org")
    expect(round_tripped["@graph"]).to eq(data.graph)
  end

  # --- The edition extension points ----------------------------------------
  #
  # These exist because the marketing pages moved to an edition and the graph
  # they contribute has to keep referencing the community nodes — an edition
  # that could not reach `software` or `id_for` would grow a second copy of the
  # @id discipline, and a drifting copy publishes a graph whose nodes do not
  # join up. That is valid JSON-LD no consumer can use, and nothing raises.
  describe "edition registrations" do
    after do
      described_class.registered_pages.delete(:test_edition_page)
      described_class.registered_offers.delete(:test_edition_offers)
    end

    it "accepts a page, and runs its block against the service's own nodes" do
      described_class.register_page(:test_edition_page) do
        [ { "@type" => "CollectionPage", "isPartOf" => { "@id" => id_for("website") } } ]
      end

      website_id = node(:home, "WebSite")["@id"]

      expect(node(:test_edition_page, "CollectionPage")["isPartOf"]).to eq("@id" => website_id)
    end

    it "names a registered page as known rather than refusing it" do
      described_class.register_page(:test_edition_page) { [] }

      expect { described_class.call(page: :test_edition_page, url_options: url_options) }
        .not_to raise_error
    end

    # Both examples empty the registry first, so they stay assertions about THIS
    # repository even when an edition is checked out and has registered real
    # offers. Otherwise they would assert something different depending on what
    # is on disk, and fail on the hosted deployment for the one reason that is
    # not a bug.
    it "publishes no offers of its own, so a deployment with no checkout advertises no price" do
      allow(described_class).to receive(:registered_offers).and_return({})

      expect(node(:home, "SoftwareApplication")).not_to have_key("offers")
    end

    it "hangs registered offers off the software node" do
      offers = proc { [ { "@type" => "Offer", "price" => "0", "url" => root_url(**@url_options) } ] }
      allow(described_class).to receive(:registered_offers).and_return(test_edition_offers: offers)

      expect(node(:home, "SoftwareApplication")["offers"].first)
        .to include("@type" => "Offer", "url" => "https://analytics.example.org/")
    end
  end
end
