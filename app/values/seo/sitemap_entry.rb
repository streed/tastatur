module Seo
  # One <url> element in sitemap.xml.
  #
  # Two fields, and the absence of the other two is the point. The sitemaps.org
  # schema also defines <changefreq> and <priority>, and every generator on the
  # internet emits them. Google has said publicly, repeatedly, that it ignores
  # both, and the other major crawlers had stopped reading them before that.
  # What they would add here is a column of numbers nobody can substantiate:
  # this application has no way to know whether /about is 0.6 important and
  # /docs is 0.8, so writing it down is decoration that reads as data.
  class SitemapEntry < Dry::Struct
    attribute :loc, Types::Strict::String

    # Set only where a real revision date exists — see Seo::BuildSitemap.
    #
    # A lastmod that says "today" every day is the same untruth that
    # Tastatur.legal_updated_on exists to keep off the legal pages, and it is
    # self-defeating besides: a crawler that catches a host claiming every page
    # changed this morning stops believing the field for that host entirely.
    # The protocol makes it optional precisely so it can be left out.
    attribute? :lastmod, Types::Strict::Date.optional
  end
end
