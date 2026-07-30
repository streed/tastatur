require "rails_helper"

# What a public page tells a crawler about itself, asserted on the rendered
# <head> rather than on the helper — the same lesson as
# spec/requests/public_identifiers_spec.rb. A metadata helper that works
# perfectly and is never called from the layout produces exactly the page we had
# before, and a unit test of the helper passes either way.
RSpec.describe "Page metadata", type: :request do
  def head_of(path, **options)
    get path, **options
    Nokogiri::HTML(response.body).at_css("head")
  end

  def meta(head, selector)
    head.at_css(selector)&.[]("content")
  end

  describe "a public page" do
    subject(:head) { head_of("/") }

    it "describes itself in one sentence" do
      expect(meta(head, 'meta[name="description"]')).to include("Cookieless, privacy-first web analytics")
    end

    it "names its own canonical URL, absolutely and on the host that was asked" do
      expect(head.at_css('link[rel="canonical"]')["href"]).to eq("http://www.example.com/")
    end

    it "carries a social card" do
      expect(meta(head, 'meta[property="og:title"]')).to eq("Tastatur — cookieless web analytics")
      expect(meta(head, 'meta[property="og:type"]')).to eq("website")
      expect(meta(head, 'meta[property="og:site_name"]')).to eq("Tastatur")
      expect(meta(head, 'meta[property="og:url"]')).to eq("http://www.example.com/")
      expect(meta(head, 'meta[property="og:image"]')).to eq("http://www.example.com/icon.png")
      expect(meta(head, 'meta[name="twitter:card"]')).to eq("summary")
    end

    # og:description and the meta description are the same sentence, from
    # Tastatur::DESCRIPTION. They used to be able to disagree because nothing
    # rendered both from one source.
    it "says the same thing to a search engine and to a link preview" do
      expect(meta(head, 'meta[property="og:description"]'))
        .to eq(meta(head, 'meta[name="description"]'))
    end

    # The default image is the square 512x512 app icon, and declaring the wide
    # card format for a square image gets it letterboxed. A deployment that sets
    # its own has supplied a designed card on purpose.
    it "upgrades to the wide card only once a real one has been configured" do
      allow(Tastatur).to receive(:social_image_configured?).and_return(true)
      allow(Tastatur).to receive(:social_image_url).and_return("https://cdn.example.org/card.png")

      head = head_of("/")

      expect(meta(head, 'meta[name="twitter:card"]')).to eq("summary_large_image")
      expect(meta(head, 'meta[property="og:image"]')).to eq("https://cdn.example.org/card.png")
    end
  end

  # A canonical tag is a claim that THIS path is the address of this content.
  # Consolidating the campaign-tagged copies of a shared link onto one URL is the
  # single thing it is for.
  it "drops the query string from the canonical URL" do
    head = head_of("/?utm_source=news.ycombinator.com&utm_campaign=launch")

    expect(head.at_css('link[rel="canonical"]')["href"]).to eq("http://www.example.com/")
  end

  it "publishes whatever host it was asked on, never a compiled-in one" do
    head = head_of("/", headers: { "HOST" => "analytics.self-hosted.example" })

    expect(head.at_css('link[rel="canonical"]')["href"]).to eq("http://analytics.self-hosted.example/")
  end

  describe "the markdown alternate" do
    it "points at the markdown rendering of the same document" do
      expect(head_of("/").at_css('link[rel="alternate"][type="text/markdown"]')["href"])
        .to eq("/index.md")

      expect(head_of("/docs").at_css('link[rel="alternate"][type="text/markdown"]')["href"])
        .to eq("/docs.md")
    end

    # Seo::BuildSitemap deliberately does not list the .md URLs — two copies of
    # one document are not two pages. `alternate` expresses the relationship
    # without asking a crawler to pick a winner.
    it "is not also offered to crawlers as a page in its own right" do
      get "/sitemap.xml"

      expect(response.body).not_to include(".md")
    end

    it "is absent from a page that has no markdown rendering" do
      expect(head_of("/privacy").at_css('link[rel="alternate"]')).to be_nil
    end
  end

  describe "JSON-LD" do
    def json_ld(path)
      head = head_of(path)
      JSON.parse(head.at_css('script[type="application/ld+json"]').text)
    end

    it "parses, and declares the schema.org context" do
      expect(json_ld("/")["@context"]).to eq("https://schema.org")
    end

    it "describes the software on the marketing page" do
      types = json_ld("/")["@graph"].map { |n| n["@type"] }

      expect(types).to include("WebSite", "SoftwareApplication")
    end

    it "describes the questions on the FAQ" do
      faq = json_ld("/faq")["@graph"].find { |n| n["@type"] == "FAQPage" }

      expect(faq["mainEntity"].map { |q| q["name"] })
        .to include("Do I need a cookie banner if I use Tastatur?")
    end

    # The one character that must not survive into a <script> block. Nothing in
    # the graph is visitor-controlled today, which is a property of the current
    # call sites rather than of the renderer — see SeoHelper#structured_data_tag.
    it "escapes angle brackets so the block cannot be closed early" do
      get "/"
      raw = response.body[%r{<script type="application/ld\+json">(.*?)</script>}m, 1]

      expect(raw).not_to include("<")
      expect(raw).not_to include(">")
    end
  end

  # THE NEGATIVE THAT THE OPT-IN DESIGN EXISTS FOR. The application layout is
  # shared with every authenticated screen. A metadata block rendered
  # unconditionally would put a customer's own domain into og:title and hand it
  # to any scraper that followed a pasted URL — the thing CLAUDE.md §10 goes to
  # some trouble to avoid everywhere else.
  describe "an authenticated page" do
    let(:user) { create(:user) }
    let(:account) { create(:account) }

    before do
      create(:membership, account: account, user: user, role: "owner")
      sign_in user
    end

    it "publishes nothing about itself" do
      site = create(:site, account: account, domain: "private.example.com")

      head = head_of("/sites/#{site.public_token}")

      expect(head.at_css('link[rel="canonical"]')).to be_nil
      expect(head.at_css('meta[name="description"]')).to be_nil
      expect(head.css('meta[property^="og:"]')).to be_empty
      expect(head.css('script[type="application/ld+json"]')).to be_empty
    end

    it "still titles the page for the person looking at it" do
      site = create(:site, account: account, domain: "private.example.com")

      head = head_of("/sites/#{site.public_token}")

      expect(head.at_css("title").text).to include("private.example.com")
    end
  end

  # A page nobody has thought about gets the old behaviour — a title and nothing
  # else — rather than a description guessed from somewhere.
  it "leaves a page that never declared itself public alone" do
    head = head_of("/users/sign_in")

    expect(head.at_css("title").text).to eq("Sign in · Tastatur")
    expect(head.at_css('meta[name="description"]')).to be_nil
  end
end
