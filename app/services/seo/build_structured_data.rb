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
    # `:home` is the SoftwareApplication node, and what Tastatur is, who wrote it
    # and what licence it carries are facts about the software rather than about
    # one deployment. Whether there is a landing page to publish it on is a
    # separate question: on a self-hosted instance `/` is the sign-in form.
    PAGES = %i[home docs pricing about faq].freeze

    def initialize(page:, url_options:)
      @page = page.to_sym
      @url_options = url_options
    end

    def call
      unless PAGES.include?(@page)
        raise ArgumentError, "no structured data for #{@page.inspect}; known pages are #{PAGES.join(', ')}"
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
      when :pricing then [ software ]
      when :about then [ software, maintainer_node ]
      when :faq then [ faq_page ]
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
    # Empty unless billing is configured: an Offer node names a price and a
    # currency, and an instance with no checkout cannot honour one.
    #
    # THE `UNLIMITED` GUARD LIVES WITH THE CODE THAT INTERPOLATES A LIMIT.
    # `Float::INFINITY` is correct everywhere else in this application and is not
    # representable in JSON, so `JSON.generate` raises on it and takes down every
    # page carrying this node.
    def plan_offers
      return [] unless Tastatur.billing_enabled?

      Billing::Plan::OFFERED.map do |plan|
        {
          "@type" => "Offer",
          "name" => plan.name,
          "price" => plan.price_display,
          "priceCurrency" => plan.currency.upcase,
          "url" => pricing_url(**@url_options),
          "availability" => "https://schema.org/InStock",
          "priceSpecification" => {
            "@type" => "UnitPriceSpecification",
            "price" => plan.price_display,
            "priceCurrency" => plan.currency.upcase,
            "referenceQuantity" => {
              "@type" => "QuantitativeValue", "value" => 1, "unitCode" => "MON"
            }
          },
          "description" => offer_description(plan)
        }
      end
    end

    def offer_description(plan)
      events = quota(plan.monthly_event_limit, "events a month")
      sites = quota(plan.site_limit, "site".pluralize(plan.site_limit == 1 ? 1 : 2))

      "#{events}, #{sites}, unlimited teammates."
    end

    def quota(value, noun)
      return "Unlimited #{noun}" if value == Billing::Plan::UNLIMITED

      "#{ActiveSupport::NumberHelper.number_to_delimited(value)} #{noun}"
    end

    def faq_page
      faq = faq_url(**@url_options)

      {
        "@type" => "FAQPage",
        "@id" => "#{faq}#faq",
        "url" => faq,
        "name" => "Tastatur — frequently asked questions",
        "isPartOf" => { "@id" => id_for("website") },
        "inLanguage" => "en",
        "mainEntity" => Seo::Faq.entries.map do |entry|
          {
            "@type" => "Question",
            "@id" => "#{faq}##{entry.anchor}",
            "name" => entry.question,
            "acceptedAnswer" => { "@type" => "Answer", "text" => entry.answer_text }
          }
        end
      }
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
