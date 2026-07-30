# The two files a crawler reads before anything else: /robots.txt and
# /sitemap.xml.
#
# INHERITS ActionController::Base, NOT ApplicationController, for the same
# reason TrackerController does — every one of ApplicationController's
# request-time behaviours would otherwise have to be skipped one at a time:
#
#   - `authenticate_user!` — both documents are for strangers by definition
#   - Pundit's verify_authorized / verify_policy_scoped — no record, no scope;
#     Seo::BuildSitemap reads nothing a policy could be asked about
#   - the first-run setup redirect — a crawler asking a half-installed instance
#     for robots.txt must be answered with robots.txt, not a 302 into a wizard
#   - `allow_browser versions: :modern`, and this one is not cosmetic. Rails
#     exempts user agents whose comment says "bot", so Googlebot and Bingbot are
#     fine; a crawler that presents itself as an old Chrome is served
#     public/406-unsupported-browser.html instead. Refusing a machine-readable
#     file over a browser feature it will never use is nonsense — these two
#     answer whatever asks for them.
#
# Four skips and a comment explaining each is a worse version of one base class
# and a comment explaining why.
class CrawlersController < ActionController::Base
  # Both files change only when the application is deployed or its billing
  # configuration changes, and no crawler needs them fresher than that. An hour
  # is also short enough that a mistake in either one can be corrected — which
  # is the property the year-long header on public/ took away.
  CACHE_FOR = 1.hour

  # WHY robots.txt IS NOT A FILE IN public/ ANY MORE. Two reasons, and /t.js hit
  # both first:
  #
  #   1. `Sitemap:` must be an absolute URL — the protocol defines no relative
  #      form — so a static file has to hardcode a host, and every self-hosted
  #      install would then point crawlers at tastatur.dev's sitemap as though
  #      it were its own.
  #   2. `config.public_file_server.headers` stamps everything under public/
  #      with `max-age=31556952` in production. One year, on a file whose whole
  #      job is to be re-read when the rules change. See TrackerController for
  #      the full version of this story, which cost a year-long cache on the
  #      tracking script.
  #
  # ActionDispatch::Static runs BEFORE the router, so this only works because
  # public/robots.txt was deleted. Putting a file back there silently restores
  # both bugs — the route stays in the routing table looking correct and is
  # never reached.
  def robots
    expires_in CACHE_FOR, public: true
  end

  def sitemap
    @entries = Seo::BuildSitemap.call(url_options: url_options).value!

    expires_in CACHE_FOR, public: true
  end
end
