require "rails_helper"

# /sitemap.xml and /robots.txt — what this instance tells a crawler about itself.
#
# The examples worth the most here are the negative ones. A sitemap exists to be
# fetched by strangers and copied into indexes, so anything tenant-specific that
# reaches it is published, permanently and to everybody. Unlisted shared
# dashboards are protected by nothing but the slug in their URL.
RSpec.describe "Crawler discovery", type: :request do
  # Nokogiri needs the default namespace stripped before a plain CSS selector
  # will match, which is worth doing rather than regexing the body: it also
  # proves the document parses.
  def sitemap_locs(body)
    Nokogiri::XML(body).remove_namespaces!.css("url > loc").map(&:text)
  end

  # The rules only, with the file's reasoning stripped out. robots.txt is mostly
  # comments here on purpose, and a `#` line is not a directive — asserting on
  # the raw body would mean a sentence explaining a rule could pass for the rule.
  def robots_directives(body)
    body.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
  end

  describe "GET /sitemap.xml" do
    it "serves a well-formed urlset" do
      get "/sitemap.xml"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/xml")

      doc = Nokogiri::XML(response.body)
      expect(doc.errors).to be_empty
      expect(doc.root.name).to eq("urlset")
      expect(doc.root.namespace.href).to eq("http://www.sitemaps.org/schemas/sitemap/0.9")
    end

    it "is XML whatever the Accept header asks for, because the path already chose" do
      get "/sitemap.xml", headers: { "Accept" => "text/html" }

      expect(response.media_type).to eq("application/xml")
    end

    it "links absolutely, on the host that was asked" do
      get "/sitemap.xml"

      expect(sitemap_locs(response.body)).to all(start_with("http://www.example.com/"))
    end

    # The lesson of spec/requests/public_identifiers_spec.rb, applied to a file
    # whose whole content is generated URLs: assert on what the app produces,
    # then follow it. A sitemap entry that redirects or 404s is reported back as
    # an error by every search console, and nothing else in the suite would
    # notice a page being listed here after it stopped being public.
    it "lists only URLs that answer 200 with no session" do
      get "/sitemap.xml"
      locs = sitemap_locs(response.body)

      expect(locs).not_to be_empty

      locs.each do |loc|
        get URI.parse(loc).path

        expect(response).to have_http_status(:ok), "#{loc} answered #{response.status}"
      end
    end

    # THE ONE THAT MATTERS. A shared link's slug is the only thing protecting an
    # unlisted dashboard, and this file is read by every crawler and scraper on
    # the internet. See Seo::BuildSitemap for why the list is written out by hand
    # rather than derived from the routing table.
    it "never lists an unlisted shared dashboard" do
      site = create(:site, domain: "private.example.com")
      link = create(:shared_link, site: site)

      get "/sitemap.xml"

      expect(response.body).not_to include(link.slug)
      expect(response.body).not_to include("/share")
      expect(response.body).not_to include(site.public_token)
      expect(response.body).not_to include(site.domain)
    end

    it "lists nothing that needs a session" do
      get "/sitemap.xml"

      %w[/sites /account /settings /billing /admin /users /sidekiq /setup /api].each do |path|
        expect(response.body).not_to include(path)
      end
    end

    it "is served before first-run setup rather than redirected into the wizard" do
      allow(Tastatur).to receive(:needs_first_run_setup?).and_return(true)

      get "/sitemap.xml"

      expect(response).to have_http_status(:ok)
    end

    # `allow_browser versions: :modern` on ApplicationController answers 406 with
    # public/406-unsupported-browser.html to anything it does not recognise as a
    # current browser. Rails exempts user agents that call themselves bots, so
    # Googlebot would have been fine — but plenty of crawlers present as an old
    # Chrome, and refusing a machine-readable file over a CSS feature it will
    # never use is nonsense. CrawlersController inherits ActionController::Base
    # so the question is never asked; this is the example that says so.
    it "answers a crawler claiming to be an ancient browser" do
      get "/sitemap.xml", headers: {
        "User-Agent" => "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 " \
                        "(KHTML, like Gecko) Chrome/41.0.2272.118 Safari/537.36"
      }

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /robots.txt" do
    it "is served by the application" do
      get "/robots.txt"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/plain")
    end

    # ActionDispatch::Static runs before the router, so a file at this path would
    # shadow the route in silence — the routing table would still look correct,
    # and the served file would carry production's one-year cache header and
    # whatever host it was written with. Same trap as public/t.js; see
    # CrawlersController.
    it "has no file in public/ that would shadow the route" do
      expect(Rails.root.join("public/robots.txt")).not_to exist
    end

    it "points at the sitemap absolutely, on the host that was asked" do
      get "/robots.txt"

      expect(robots_directives(response.body)).to include("Sitemap: http://www.example.com/sitemap.xml")
    end

    it "keeps crawlers out of the authenticated application" do
      get "/robots.txt"

      directives = robots_directives(response.body)

      %w[/sites/ /account /settings/ /billing /admin/ /users/ /sidekiq /api/].each do |path|
        expect(directives).to include("Disallow: #{path}")
      end
    end

    # DELIBERATELY BACKWARDS-LOOKING. Blocking /share/ here is what would put a
    # shared dashboard into a search index: a crawler that is refused the page
    # never reads the `noindex` meta tag it carries, so a URL it learned from a
    # leaked referrer stays indexed — publishing the slug, which is the secret.
    # Left crawlable, the noindex is obeyed and the URL is dropped outright.
    it "does not disallow /share/, so its noindex can be read and obeyed" do
      get "/robots.txt"

      expect(robots_directives(response.body)).not_to include(a_string_matching(%r{^Disallow: /share}))
    end

    it "still says so to a crawler claiming to be an ancient browser" do
      get "/robots.txt", headers: {
        "User-Agent" => "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 " \
                        "(KHTML, like Gecko) Chrome/41.0.2272.118 Safari/537.36"
      }

      expect(response).to have_http_status(:ok)
    end

    it "is served before first-run setup, like the sitemap" do
      allow(Tastatur).to receive(:needs_first_run_setup?).and_return(true)

      get "/robots.txt"

      expect(response).to have_http_status(:ok)
    end
  end
end
