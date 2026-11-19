module Seo
  # Everything on this instance a search engine should be told about.
  #
  # THE LIST IS WRITTEN OUT, NOT DERIVED, and that is the whole security
  # argument for this file. Walking `Rails.application.routes.routes` and
  # keeping every GET that does not require a session would be a third of the
  # code and would publish `/share/:slug`, which is unauthenticated by design.
  # That slug is the only thing standing between an unlisted dashboard and the
  # open web (SharedLink, CLAUDE.md §10) — and a sitemap is the one file on the
  # instance whose entire purpose is to be fetched by strangers and copied into
  # indexes. A customer who shared one dashboard with one client would have
  # handed it to every crawler on the internet, and nothing would have told
  # them.
  #
  # So each line below is a literal route helper for a page that is public
  # *content*: something written to be read by anyone, that says the same thing
  # to everyone. Adding a page to the sitemap means adding a line here, on
  # purpose, having thought about it. spec/requests/sitemap_spec.rb fetches
  # every URL this returns with no session and asserts a 200, so a line added
  # carelessly fails the suite instead of shipping.
  #
  # Alternate representations of these pages — /index.md, /docs.md, the
  # `Accept: text/markdown` renderings — are deliberately absent. They are the
  # same documents in another costume; llms.txt is where a machine reader is
  # pointed at them, and listing them here would only ask a crawler to decide
  # which copy is canonical.
  class BuildSitemap < ApplicationService
    include Rails.application.routes.url_helpers

    # `url_options` comes from the controller, so every <loc> is absolute on the
    # host the crawler actually asked — exactly like llms.txt. A self-hosted
    # install then publishes its own domain instead of advertising ours.
    def initialize(url_options:)
      @url_options = url_options
    end

    def call
      Success(pages + marketing + policies)
    end

    private

    # The pages every deployment has: /docs explains how to use the software, and
    # says the same thing on the hosted service as on somebody's own hardware.
    #
    # `/` IS DELIBERATELY ABSENT HERE. On a deployment with no marketing site the
    # root path is the sign-in form (PagesController#home), and every line in
    # this file is a page of public *content* — something written to be read by
    # anyone, that says the same thing to everyone. A sign-in form is neither, it
    # declares no metadata for a crawler to read, and the entry would be a
    # redirect, which every search console reports back as an error rather than
    # following. A deployment that serves a landing page at `/` lists it in
    # `marketing` below.
    def pages
      [ SitemapEntry.new(loc: docs_url(**@url_options)) ]
    end

    # The marketing site's pages, on a deployment that serves one. Written out by
    # hand like everything else here, and for the same reason: the security
    # argument at the top of this file applies unchanged.
    #
    # `/` is listed here and not in `pages` because only a deployment with a
    # marketing site has a landing page there; elsewhere it is the sign-in form,
    # a redirect, which every search console reports as an error.
    def marketing
      return [] unless Tastatur.marketing_site?

      urls = [
        root_url(**@url_options),
        faq_url(**@url_options),
        about_url(**@url_options),
        revenue_url(**@url_options)
      ]

      urls << pricing_url(**@url_options) if Tastatur.billing_enabled?

      urls.map { |loc| SitemapEntry.new(loc: loc) }
    end

    def policies
      [
        SitemapEntry.new(loc: privacy_url(**@url_options)),
        SitemapEntry.new(loc: privacy_policy_url(**@url_options), lastmod: legal_updated_on),
        SitemapEntry.new(loc: terms_url(**@url_options), lastmod: legal_updated_on),
        SitemapEntry.new(loc: dpa_url(**@url_options))
      ]
    end

    # LEGAL_UPDATED_ON is the only revision date this application actually
    # knows, and it belongs to the two documents that print it: the privacy
    # policy and the terms. Everything else gets no <lastmod> at all, because
    # the honest answer for a page whose copy changes with a deploy is that we
    # do not track when it last changed. Returns nil when unset, which omits the
    # element — see Seo::SitemapEntry.
    def legal_updated_on
      Tastatur.legal[:updated_on]
    end
  end
end
