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
    expect(node(:faq, "FAQPage")["isPartOf"]).to eq("@id" => website_id)
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

  describe "offers" do
    it "publishes one per plan on offer, priced per month" do
      offers = node(:pricing, "SoftwareApplication")["offers"]

      expect(offers.map { |o| o["name"] }).to eq(%w[Free Pro])
      expect(offers.last).to include("price" => "30", "priceCurrency" => "USD")
      expect(offers.last.dig("priceSpecification", "referenceQuantity"))
        .to include("value" => 1, "unitCode" => "MON")
    end

    # An instance that cannot take a payment must not advertise a price. Same
    # condition, and the same reasoning, as the pricing entries in
    # Seo::BuildSitemap and llms.txt.
    it "are omitted where this instance cannot charge for anything" do
      allow(Tastatur).to receive(:billing_enabled?).and_return(false)

      expect(node(:home, "SoftwareApplication")).not_to have_key("offers")
    end

    # THE ONE THAT WOULD HAVE BEEN A 500 ON THE MARKETING PAGE.
    # Billing::Plan::UNLIMITED is Float::INFINITY, which is correct everywhere
    # else in the application and is not representable in JSON — `JSON.generate`
    # raises on it. Nothing in OFFERED is unlimited today, so this pins the guard
    # against the edit that adds one, three files away from the page that breaks.
    it "survives a plan with no ceiling instead of producing unserialisable JSON" do
      stub_const("Billing::Plan::OFFERED", [ Billing::Plan.self_hosted ])

      offer = node(:pricing, "SoftwareApplication")["offers"].first

      expect(offer["description"]).to eq("Unlimited events a month, Unlimited sites, unlimited teammates.")
      expect { JSON.generate(graph_for(:pricing)) }.not_to raise_error
    end
  end

  describe "the FAQ page node" do
    subject(:faq) { node(:faq, "FAQPage") }

    it "asks every question in the catalogue, with one accepted answer each" do
      questions = faq["mainEntity"]

      expect(questions.map { |q| q["name"] }).to eq(Seo::Faq.entries.map(&:question))
      expect(questions.map { |q| q["@type"] }.uniq).to eq(["Question"])
      expect(questions.map { |q| q.dig("acceptedAnswer", "@type") }.uniq).to eq(["Answer"])
    end

    # THE ANTI-CLOAKING GUARANTEE. A FAQPage whose structured answers differ
    # from the ones a reader sees is treated as cloaking and the markup is
    # discarded at best. Both come from Seo::Faq, and this is the example that
    # says a future refactor may not quietly reintroduce a second copy.
    it "answers each question with the same text the page shows a reader" do
      Seo::Faq.entries.each do |entry|
        question = faq["mainEntity"].find { |q| q["name"] == entry.question }

        expect(question.dig("acceptedAnswer", "text")).to eq(entry.answer_text)
        expect(question["@id"]).to end_with("/faq##{entry.anchor}")
      end
    end

    it "drops the pricing question where there is nothing to buy" do
      allow(Tastatur).to receive(:billing_enabled?).and_return(false)

      names = node(:faq, "FAQPage")["mainEntity"].map { |q| q["name"] }

      expect(names).not_to include(a_string_matching(/cost/i))
      expect(names).to include(a_string_matching(/cookie banner/i))
    end
  end

  it "serialises to JSON that parses back to the same graph" do
    data = described_class.call(page: :faq, url_options: url_options).value!

    round_tripped = JSON.parse(JSON.generate(data.to_json_ld))

    expect(round_tripped["@context"]).to eq("https://schema.org")
    expect(round_tripped["@graph"]).to eq(data.graph)
  end
end
