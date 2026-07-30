module SeoHelper
  # What a public page tells a crawler about itself.
  #
  # OPT-IN, PAGE BY PAGE, and that is the same decision Seo::BuildSitemap makes
  # for the same reason. The application layout is shared by the marketing site
  # and by every authenticated screen, so a block rendered unconditionally would
  # describe a customer's dashboard to a link scraper — `og:title` on
  # /sites/:token is that customer's domain name, and the whole point of §10 is
  # that we do not hand those out. Publishing is a deliberate act; a page that
  # wants to be indexed says so.
  #
  # It also keeps the canonical tag honest. A canonical URL is a claim that this
  # path is THE address of this content, and dropping the query string to build
  # one is right for /docs and flatly wrong for a filtered dashboard, where
  # ?path=/pricing is a different report. Emitting it only where a human decided
  # to means the claim is never made by accident.
  #
  # Usage, once, at the top of a public template:
  #
  #   <% seo title: "Pricing · Tastatur",
  #          description: "Two plans...",
  #          structured_data: :pricing %>
  #
  # It replaces the `content_for :title` line rather than sitting next to it —
  # two places setting the title is how you get "Pricing · Tastatur · Tastatur",
  # since content_for appends.
  def seo(title:, description:, og_type: "website", markdown: nil, structured_data: nil)
    content_for :title, title

    @seo_metadata = Seo::PageMetadata.new(
      title: title,
      description: description,
      canonical: canonical_url,
      og_type: og_type,
      image: Tastatur.social_image_url(base: request.base_url),
      markdown: markdown
    )
    @seo_structured_data = structured_data

    nil
  end

  # Absolute, on the host that was actually asked for — never a compiled-in one,
  # for the reason spelled out at length in CrawlersController: a self-hosted
  # install must publish its own domain and not advertise ours.
  #
  # The query string is dropped. Every page that opts into this block is one
  # whose content does not vary by parameter, so `?utm_source=...` and
  # `?ref=hn` arriving on a shared link should consolidate onto one URL rather
  # than splitting the page's standing across a dozen near-duplicates. That is
  # the single thing a canonical tag is for.
  def canonical_url
    "#{request.base_url}#{request.path}"
  end

  # Rendered from the layout. Returns nothing at all on a page that did not
  # declare itself public, which is most of them.
  def seo_tags
    meta = @seo_metadata
    return if meta.nil?

    tags = [
      tag.meta(name: "description", content: meta.description),
      tag.link(rel: "canonical", href: meta.canonical),

      tag.meta(property: "og:type", content: meta.og_type),
      tag.meta(property: "og:site_name", content: "Tastatur"),
      tag.meta(property: "og:title", content: meta.title),
      tag.meta(property: "og:description", content: meta.description),
      tag.meta(property: "og:url", content: meta.canonical),

      tag.meta(name: "twitter:card", content: twitter_card_type),
      tag.meta(name: "twitter:title", content: meta.title),
      tag.meta(name: "twitter:description", content: meta.description)
    ]

    if meta.image
      tags << tag.meta(property: "og:image", content: meta.image)
      tags << tag.meta(name: "twitter:image", content: meta.image)
    end

    # The markdown rendering of this same page. See Seo::PageMetadata#markdown
    # for why this is `alternate` and not a second sitemap entry.
    if meta.markdown
      tags << tag.link(rel: "alternate", type: "text/markdown", href: meta.markdown,
                       title: "#{meta.title} (markdown)")
    end

    tags << structured_data_tag(@seo_structured_data) if @seo_structured_data

    safe_join(tags, "\n    ")
  end

  private

  # `summary` is the honest default because the image this instance ships is
  # /icon.png, which is square. Declaring `summary_large_image` for a square
  # image gets it letterboxed with bars down both sides, which looks like a
  # broken deployment rather than a design choice. A deployment that has set
  # SOCIAL_IMAGE_URL has supplied a card on purpose and is presumed to have made
  # it the wide shape those cards are.
  def twitter_card_type
    Tastatur.social_image_configured? ? "summary_large_image" : "summary"
  end

  # JSON-LD goes inside a <script>, so the one thing that must not survive into
  # the document is a literal `</script>`. `ERB::Util.json_escape` replaces `<`,
  # `>` and `&` with their \u escapes, which JSON parsers read identically and
  # an HTML tokeniser cannot end a script block on. Marking the result html_safe
  # after that is what stops Rails escaping the JSON's own quotes into entities
  # and handing every consumer an unparseable document.
  #
  # Nothing in the graph comes from a visitor today — it is constants, route
  # helpers and instance configuration. The escaping is here because "nothing
  # user-controlled reaches this" is a property of the current call sites, not of
  # the function, and the next person to add a node will not read this comment.
  def structured_data_tag(page)
    data = Seo::BuildStructuredData.call(page: page, url_options: url_options).value!
    json = ERB::Util.json_escape(JSON.generate(data.to_json_ld))

    tag.script(json.html_safe, type: "application/ld+json")
  end
end
