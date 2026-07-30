# Serves the tracking script.
#
# WHY THIS IS NOT A STATIC FILE ANY MORE.
#
# t.js used to live in public/ and be served by ActionDispatch::Static, which
# stamps every file it serves with `config.public_file_server.headers` — in
# production, `max-age=31556952`. One year.
#
# That is the right header for a digest-stamped asset and exactly the wrong one
# here. The snippet a customer pastes embeds the bare path `/t.js`, so there is no
# filename to change and therefore no way to invalidate it. Ship a fix to the
# tracker and returning visitors keep the old copy for a year.
#
# config/Caddyfile already corrected this for the bundled compose deployment. That
# is not enough: Railway has no Caddy in front, and the year-long header is what
# actually shipped to production. Measured on the live site before this change:
#
#     $ curl -sI https://tastatur.dev/t.js
#     cache-control: public, max-age=31556952
#
# Serving it from the application makes the header correct everywhere, with or
# without a proxy, which is the only version of "correct" worth having for a file
# that runs on other people's websites.
#
# ActionDispatch::Static runs BEFORE the router, so this only works because the
# file was moved out of public/. Putting it back would silently restore the bug.
class TrackerController < ActionController::Base
  # Inherits ActionController::Base, NOT ApplicationController, and that is
  # deliberate:
  #
  #   - ApplicationController calls `allow_browser versions: :modern`, which would
  #     refuse to serve the tracker to exactly the older browsers whose visits the
  #     customer is trying to count. The measurement script must run where the
  #     visitors are, not where we wish they were.
  #   - It also runs Pundit's verify_authorized / verify_policy_scoped after_actions
  #     and the Devise session machinery, none of which mean anything for a public
  #     static asset requested by a stranger's browser.
  #
  # Forgery protection is skipped ENTIRELY, and this is the line that makes the
  # controller work at all.
  #
  # Rails guards against a cross-origin `<script src>` reading a JavaScript
  # response, because for a normal app such a response can leak per-session data
  # to whoever embedded it. Requesting /t.js from another origin therefore raised:
  #
  #   Security warning: an embedded <script> tag on another site requested
  #   protected JavaScript.
  #
  # Which is precisely what this endpoint is for. The tracker is embedded by
  # `<script src>` on every customer's site and is cross-origin by definition, so
  # the check would have broken it for every installation — while a static file in
  # public/ was never subject to it. That is why this was invisible until the file
  # moved, and why it is tested.
  #
  # Safe here because there is nothing to leak: the response is one fixed file,
  # identical for every requester, with no session read and no per-user branch.
  # `null_session` is NOT sufficient — it changes what the session is, not whether
  # the cross-origin JavaScript check runs.
  skip_forgery_protection

  PATH = Rails.root.join("lib/tracker/t.js")

  # Read once at boot rather than per request. The file cannot change while the
  # process runs — a deploy replaces the container — so re-reading it on the hot
  # path would be a syscall per visitor for no benefit.
  SOURCE = PATH.read.freeze
  VERSION = Digest::SHA256.hexdigest(SOURCE).first(16).freeze

  # One hour, with a day of stale-while-revalidate behind it.
  #
  # The short window IS the invalidation lever, since the filename carries no
  # digest. stale-while-revalidate means the visitor still gets an instant response
  # from cache after it expires, and the refresh happens out of band — so honesty
  # about staleness costs nothing in page speed.
  MAX_AGE = 1.hour
  STALE_WHILE_REVALIDATE = 1.day

  def show
    expires_in MAX_AGE, public: true,
                        "stale-while-revalidate": STALE_WHILE_REVALIDATE.to_i

    # ETag on the content hash, so a revalidation after the hour is 304 and a few
    # hundred bytes rather than the whole script again.
    return unless stale?(etag: VERSION, public: true)

    render plain: SOURCE, content_type: "text/javascript"
  end
end
