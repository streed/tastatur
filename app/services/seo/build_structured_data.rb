module Seo
  # The schema.org graph for one public page.
  #
  # This is the half of the SEO work that is aimed at machines rather than
  # people. A meta description is a hint a search engine may use; JSON-LD is the
  # page stating in a parseable form what it is, what the product costs, and —
  # on /faq — which questions it answers and what the answers are. That last one
  # is the whole reason this file exists: an answer engine quoting a page has to
  # decide which span of text is the answer to the question it was asked, and a
  # FAQPage node removes the guess.
  #
  # THE AUTHOR AND THE OPERATOR ARE DIFFERENT NODES, and keeping them apart
  # matters more here than anywhere else in the application, because this is the
  # one place the distinction gets published in machine-readable form. Tastatur
  # was written by Reedster LLC — a fixed fact, true of every copy — so it is the
  # `author` of the SoftwareApplication on every instance. Who *operates* the
  # instance being crawled is a different question with a different answer on a
  # self-hosted install, so the Organization node is emitted only where
  # `Tastatur.legal_configured?` says somebody has actually said who they are.
  # Emitting Reedster LLC as the publisher of a stranger's self-hosted analytics
  # install would be the JSON-LD version of the bug CrawlersController exists to
  # avoid: every copy of the software advertising ours as its own.
  #
  # `url_options` comes from the caller so every @id and url is absolute on the
  # host actually being served, exactly like Seo::BuildSitemap and llms.txt.
  class BuildStructuredData < ApplicationService
    include Rails.application.routes.url_helpers

    # AGPL-3.0, named by its canonical URL rather than the string "AGPL-3.0",
    # because `license` expects something dereferenceable.
    LICENSE_URL = "https://www.gnu.org/licenses/agpl-3.0.html".freeze

    # Pages that have a graph worth publishing. Unknown keys raise rather than
    # returning an empty graph: a typo in a view should fail in the suite, not
    # silently ship a page with its structured data missing — which is precisely
    # the class of failure nothing else would notice, since the page still looks
    # perfect to a human.
    #
    # `:home` stays here even though this repository serves no landing page — its
    # graph is the SoftwareApplication node, and what Tastatur is, who wrote it
    # and what licence it carries are facts about the software rather than about
    # one deployment. So the graph is this repository's to state; whether there
    # is a page to publish it on is a separate question, and today only an
    # edition puts one at `/`.
    #
    # An edition's own pages — /pricing, /faq and /about are the hosted
    # service's — arrive through `register_page` below and are just as much a
    # hard error when misspelled.
    PAGES = %i[home docs].freeze

    # --- Edition extension points --------------------------------------------
    #
    # Both take a block that is `instance_exec`'d on the service, so an edition
    # writes `software`, `id_for("website")` and `faq_url(**@url_options)` the
    # same way the nodes below do. That is deliberate: the alternative is
    # duplicating the @id-and-absolute-URL discipline in a second repository,
    # where a drifting copy would publish a graph whose nodes do not reference
    # each other — valid JSON-LD that no consumer can join up, and nothing would
    # raise.
    #
    # Keyed for the same reason BuildSitemap's registrations are: to_prepare
    # re-registers on every reload in development.
    def self.register_page(page, &block)
      registered_pages[page.to_sym] = block
    end

    def self.registered_pages
      @registered_pages ||= {}
    end

    # What a SoftwareApplication node costs. Empty here, because the community
    # edition sells nothing and a deployment with no checkout must not publish an
    # Offer — the same condition that keeps /pricing out of the sitemap.
    def self.register_offers(key, &block)
      registered_offers[key.to_sym] = block
    end

    def self.registered_offers
      @registered_offers ||= {}
    end

    def initialize(page:, url_options:)
      @page = page.to_sym
      @url_options = url_options
    end

    def call
      known = PAGES + self.class.registered_pages.keys
      unless known.include?(@page)
        raise ArgumentError, "no structured data for #{@page.inspect}; known pages are #{known.join(', ')}"
      end

      Success(StructuredData.new(graph: [ website, *operator, *page_nodes ].compact))
    end

    private

    # --- Sitewide ------------------------------------------------------------

    def website
      {
        "@type" => "WebSite",
        "@id" => id_for("website"),
        "url" => root_url(**@url_options),
        "name" => "Tastatur",
        "description" => Tastatur::DESCRIPTION,
        "inLanguage" => "en"
      }
    end

    # Who runs THIS instance. Absent by default and absent forever on a
    # self-hosted install whose operator never filled the variables in — the same
    # position the /privacy-policy page takes, where an unconfigured instance
    # renders a banner saying so rather than quietly publishing a plausible name.
    # Name and URL only. The operator's contact address and postal address are
    # both configured and both already printed on /privacy-policy, so leaving
    # them out here withholds nothing from a reader — but a JSON-LD block is a
    # machine-readable document served to every scraper that asks, which is a
    # materially easier thing to harvest an address out of than a paragraph. The
    # node exists to establish who this instance belongs to, and `name` and `url`
    # are the two fields that do that.
    def operator
      return [] unless Tastatur.legal_configured?

      [ {
        "@type" => "Organization",
        "@id" => id_for("operator"),
        "name" => Tastatur.legal_value(:entity),
        "url" => root_url(**@url_options)
      } ]
    end

    # The fixed fact: who wrote the software. Inlined rather than given an @id,
    # because on a self-hosted install this organisation is not the publisher of
    # the site being crawled and should not be reachable as though it were.
    def maintainer_node
      {
        "@type" => "Organization",
        "name" => Tastatur.maintainer[:name],
        "url" => Tastatur.maintainer[:url]
      }
    end

    # --- Per page ------------------------------------------------------------

    def page_nodes
      case @page
      when :home then [ software ]
      when :docs then [ tech_article ]
      else Array(instance_exec(&self.class.registered_pages.fetch(@page)))
      end
    end

    def software
      node = {
        "@type" => "SoftwareApplication",
        "@id" => id_for("software"),
        "name" => "Tastatur",
        "url" => root_url(**@url_options),
        "description" => Tastatur::DESCRIPTION,
        "applicationCategory" => "BusinessApplication",
        "applicationSubCategory" => "Web analytics",
        # A hosted web application runs wherever a browser does. The property is
        # required for rich results and omitting it drops the node entirely.
        "operatingSystem" => "Any",
        "softwareVersion" => Tastatur.version,
        "license" => LICENSE_URL,
        "isAccessibleForFree" => true,
        "author" => maintainer_node,
        "inLanguage" => "en"
      }

      offers = plan_offers
      node["offers"] = offers if offers.any?
      node
    end

    # What this instance sells, if anything.
    #
    # Empty in the community edition and that is not a placeholder: an Offer node
    # names a price and a currency, and the community edition has no checkout to
    # honour one. The hosted edition registers the real offers, which is also
    # where the `Billing::Plan::UNLIMITED` guard lives — `Float::INFINITY` is
    # correct everywhere else in this application and is not representable in
    # JSON, so `JSON.generate` raises on it and takes down every page carrying
    # this node. Keep that guard with the code that interpolates a limit.
    def plan_offers
      self.class.registered_offers.values.flat_map { |block| instance_exec(&block) }
    end

    def tech_article
      {
        "@type" => "TechArticle",
        "@id" => "#{docs_url(**@url_options)}#article",
        "headline" => "Using Tastatur",
        "url" => docs_url(**@url_options),
        "description" => "How to install Tastatur, send custom events and revenue, measure " \
                         "single-page apps, define goals and funnels, and call the ingest API directly.",
        "author" => maintainer_node,
        "isPartOf" => { "@id" => id_for("website") },
        "about" => { "@id" => id_for("software") },
        "inLanguage" => "en",
        "license" => LICENSE_URL
      }
    end

    def id_for(fragment)
      "#{root_url(**@url_options)}##{fragment}"
    end
  end
end
