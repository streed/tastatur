---
paths:
  - "app/views/crawlers/**/*.erb"
  - "app/controllers/crawlers_controller.rb"
  - "app/controllers/pages_controller.rb"
  - "app/services/seo/**/*.rb"
  - "app/assets/**/*.css"
  - "config/routes.rb"
  - "spec/requests/country_flags_spec.rb"
  - "spec/requests/root_spec.rb"
  - "spec/requests/sitemap_spec.rb"
  - "docs/development.md"
---

### 12. Things that look like bugs but are deliberate (public pages and assets)

Before "fixing" any of these, read the linked document.

- **`"Tastatur Flags"` is first in `--font-sans`, and that position is the
  feature.** The country breakdown composes a flag out of the country code — two
  regional indicator letters — which macOS and Linux render from their own emoji
  fonts and **Windows does not**: Segoe UI Emoji ships no flag glyphs, and since
  it covers the two letters individually, fallback stops there and draws two
  boxed capitals. So we ship a 76KB webfont covering exactly `U+1F1E6-1F1FF`, and
  it has to be ahead of every system emoji family or Windows never reaches it.
  Tidying it to the end of the list, or dropping the `unicode-range` that keeps
  it off pages with no flags, are both invisible from Ruby —
  `spec/requests/country_flags_spec.rb` asserts the stack order for that reason.
  `docs/development.md`

- **`robots.txt` does not disallow `/share/`,** and adding that line is the way
  to publish an unlisted dashboard rather than hide one. A crawler refused the
  page never loads the `noindex` meta tag it carries, so a slug that leaked
  through a referrer stays indexed — and the slug is the secret. Left crawlable,
  the tag is obeyed and the URL is dropped outright.
  `app/views/crawlers/robots.text.erb`
- **The sitemap lists literal route helpers** instead of walking the routing
  table for public GETs. The derived version is shorter and publishes
  `/share/:slug`, which is unauthenticated by design. Adding a page to
  `Seo::BuildSitemap` is meant to be a deliberate edit.

- **`robots.txt` and `sitemap.xml` are served by the application, and
  `public/robots.txt` must stay deleted.** `ActionDispatch::Static` runs before
  the router, so a file there shadows the route silently while production stamps
  it with a one-year cache header — the `/t.js` bug again. `Sitemap:` also has
  no relative form, so a static file would advertise our host on every
  self-hosted install. `CrawlersController`
- **On a self-hosted instance `/` forwards to the sign-in form, and there is no
  landing page.** A page arguing for Tastatur has nothing to say to somebody who
  has already installed it on their own hardware, and everything such a page would
  tell them is somewhere better: what it collects on `/privacy`, how to install
  it on `/docs`, and the version, the licence and the author in the footer of
  every screen. What remains of a front door on an instance you must sign in to
  use is the sign-in form. The hosted service's marketing `/` is routed ahead of
  it, behind `Tastatur.marketing_site?` (§20). Two consequences that look like
  omissions: the forward is **absent from `Seo::BuildSitemap`** (the marketing home
  is listed instead, and only where it exists), because a form is not public
  content and the entry would be a redirect, which a search console reports as an
  error; and it **forwards rather than routing root
  into `users/sessions#new`**, because Devise's `require_no_authentication`
  answers an already-signed-in visitor with "You are already signed in." and a
  redirect to `signed_in_root_path`, which is `root_path` itself — so the header
  logo, which links there from every screen, would loop or scold. `PagesController`
