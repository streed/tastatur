module Seo
  # Everything one public page tells a crawler about itself, above the content:
  # the title, the one-sentence description, the canonical URL, and the social
  # card. Rendered by SeoHelper#seo_tags into the application layout.
  #
  # THE DESCRIPTION IS REQUIRED, and that is the only reason this is a struct
  # rather than a hash. A page that opts into this block has opted into being
  # indexed and summarised, and the summary is the part that cannot be derived:
  # a title is already in the layout and a canonical URL is already in the
  # request, but nothing in the application knows how to say what /dpa is for in
  # one sentence. Left optional it would have been omitted from exactly the
  # pages nobody thought hard about, which are the pages that most need it —
  # a crawler with no description writes its own from whatever text it finds
  # first, and on these pages that is a nav bar.
  #
  # Note what is NOT here. No keywords meta — no major engine has read it in
  # twenty years and it is a reliable spam signal. No robots directive: the two
  # places in this application that need one already carry it deliberately (the
  # public dashboard layout's noindex) or deliberately do not (robots.txt and
  # /share/, see CrawlersController), and a third way to set it would be a way
  # to contradict them.
  class PageMetadata < Dry::Struct
    attribute :title, Types::Strict::String
    attribute :description, Types::Strict::String

    # Absolute, on the host the visitor actually asked for, and always without a
    # query string — see SeoHelper#canonical_url for why that is safe here and
    # would not be on a filtered dashboard.
    attribute :canonical, Types::Strict::String

    # og:type. "website" for the marketing and policy pages, "article" for the
    # documentation and the FAQ, which are documents rather than destinations.
    attribute :og_type, Types::Strict::String.default("website".freeze)

    attribute? :image, Types::Strict::String.optional.default(nil)

    # The markdown rendering of this same page, where one exists.
    #
    # Emitted as <link rel="alternate" type="text/markdown">, which is the
    # standards-shaped way to say "same document, other format" — the same
    # relationship RSS feeds have always been declared with. Seo::BuildSitemap
    # deliberately does NOT list these URLs, because a sitemap entry is a claim
    # that a page is a separate thing worth indexing and two copies of one
    # document are not. `alternate` says the opposite and is therefore the right
    # place: it points a machine reader at the markdown while telling a search
    # engine which copy is canonical.
    attribute? :markdown, Types::Strict::String.optional.default(nil)
  end
end
