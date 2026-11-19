require "rails_helper"
require "nokogiri"

# The metadata the marketing pages publish. spec/requests/page_metadata_spec.rb
# asserts the rules — opt-in per page, canonical without the query string, nothing
# at all on an authenticated screen — and this asserts that the marketing pages
# follow them.
RSpec.describe "Marketing page metadata", type: :request do
  def head_of(path)
    get path
    Nokogiri::HTML(response.body).at_css("head")
  end

  def json_ld(path)
    head_of(path).at_css('script[type="application/ld+json"]').then { |s| JSON.parse(s.text) }
  end

  it "points the landing page at its own markdown rendering" do
    expect(head_of("/").at_css('link[rel="alternate"][type="text/markdown"]')["href"])
      .to eq("/index.md")
  end

  it "describes the questions on the FAQ" do
    faq = json_ld("/faq")["@graph"].find { |n| n["@type"] == "FAQPage" }

    expect(faq["mainEntity"].map { |q| q["name"] })
      .to include("Do I need a cookie banner if I use Tastatur?")
  end

  # The rule page_metadata_spec.rb states and the marketing pages are the most
  # likely place to break, because a marketing page is exactly the kind of page someone
  # adds without thinking about the block.
  it "describes the software on the landing page" do
    types = json_ld("/")["@graph"].map { |n| n["@type"] }

    expect(types).to include("WebSite", "SoftwareApplication")
  end
end
