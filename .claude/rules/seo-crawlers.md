---
paths:
  - "app/helpers/seo_helper.rb"
  - "app/services/seo/**/*.rb"
  - "app/values/seo/**/*.rb"
  - "app/views/crawlers/**/*.erb"
  - "app/views/layouts/**/*.erb"
  - "app/controllers/crawlers_controller.rb"
  - "spec/requests/page_metadata_spec.rb"
  - "spec/requests/sitemap_spec.rb"
  - "docs/privacy/claims.md"
---

### 17. What a crawler and an answer engine are told

Four surfaces publish this instance to machines: `robots.txt` and `sitemap.xml`
(§12), `llms.txt`, and the metadata block in the application layout. The
mechanisms and the marketing pages they describe are all here; the marketing pages
and their sitemap and JSON-LD entries are present only where
`Tastatur.marketing_site?` (§20). The rules:

- **The metadata block is opt-in, page by page.** `SeoHelper#seo` sets the title,
  description, canonical, Open Graph and Twitter tags and the JSON-LD; a page that
  does not call it renders exactly the `<title>` it always did. This is the same
  decision `Seo::BuildSitemap` makes and it is not tidiness. The application layout
  is shared with every authenticated screen, so a block rendered unconditionally
  would put a customer's own domain into `og:title` on `/sites/:token` and hand it
  to any scraper that followed a pasted link — the thing §10 exists to prevent. It
  also keeps the canonical tag honest: dropping the query string to build one is
  right for `/docs` and flatly wrong for a filtered dashboard, where `?path=/x` is
  a different report. `spec/requests/page_metadata_spec.rb` asserts the block is
  absent on an authenticated page.
- **`seo` replaces `content_for :title`, it does not accompany it.** `content_for`
  appends, so two callers produce "Pricing · Tastatur · Tastatur".
- **One sentence describes the product, and it lives in `Tastatur::DESCRIPTION`.**
  Five things quote it and four of them are invisible in a browser — the meta
  description, `og:description`, and the `description` of both the `WebSite` and
  `SoftwareApplication` nodes — so a drifting copy is not something anyone would
  notice by looking at the site.
- **The author and the operator are different JSON-LD nodes.** Reedster LLC wrote
  every copy, so it is `author` on every instance. Who *operates* the instance is a
  different question with a different answer on a self-hosted install, so the
  `Organization` node appears only where `Tastatur.legal_configured?`. Publishing
  ours as the operator of a stranger's install is the `Sitemap:` bug in another
  costume. That node carries name and URL only — the operator's contact address is
  already on `/privacy-policy` in prose, and restating it in a machine-readable
  block served to every scraper is a harvesting convenience, not a disclosure.
- **Never interpolate a plan limit into JSON-LD without the `UNLIMITED` guard.**
  `Billing::Plan::UNLIMITED` is `Float::INFINITY`, which is correct everywhere else
  and is not representable in JSON — `JSON.generate` raises on it. Only `FREE` and
  `PRO` are in `OFFERED` today, so the failure is one edit away and would surface
  as a 500 on the marketing page, three files from the cause. The guard lives
  in `Seo::BuildStructuredData#plan_offers`, which publishes no `Offer` node at all
  unless `Tastatur.billing_enabled?`, because an instance with no checkout cannot
  honour a price.
- **The `.md` renderings are `rel="alternate"`, never sitemap entries.** Two copies
  of one document are not two pages; `alternate` points a machine reader at the
  markdown while telling a search engine which copy is canonical.
- **The FAQ and the marketing pages are bound by `docs/privacy/claims.md`.** The
  claims are the product's, not one deployment's — a self-hoster quoting our copy
  inherits the same ban. The FAQ is the most likely place in the application for a banned claim to reappear,
  because a FAQ is written in the voice of the question and the question is usually
  the banned claim ("Is Tastatur GDPR compliant?"). The ban applies to **answers,
  not questions** — a heading quoting a reader asserts nothing.
- **Adding a public page here means adding it to `Seo::BuildSitemap` by hand,** and
  that includes the marketing pages, in `Seo::BuildSitemap#marketing`: the list is
  written out, never derived. `spec/requests/sitemap_spec.rb` fetches every URL the service
  returns with no session, so a careless line fails the suite instead of shipping.
  The list is `/docs`, the four compliance pages and, where there is a marketing
  site, its pages. On a self-hosted instance `/` is not on it, for the reason §12
  gives.
- **Markdown templates are whitespace-sensitive and ERB eats whitespace.** Rails
  trims any line holding only a scriptlet tag, newline included. Paragraphs emitted
  one per line through a loop arrive with nothing between them and render as one
  run-on paragraph — every word present, all structure gone. Join on a double
  newline instead. And remember an ERB comment ends at the first closing delimiter
  inside it, so a comment showing an example tag prints its own remainder into the
  document (the trap already documented in `crawlers/sitemap.xml.erb`).
