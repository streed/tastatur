# Content Security Policy.
#
# This file used to be the generated one with every line still commented out, so
# no CSP header was sent at all. Rails' own `default_headers` covered
# X-Frame-Options, nosniff and Referrer-Policy, and config/Caddyfile set those
# again — but Caddy is only in front of the bundled compose deployment. Railway
# has nothing in front, so a header that exists only in the Caddyfile is a header
# production does not have. That is the same mistake TrackerController documents
# about the year-long cache header on /t.js, and the fix is the same one: put it
# in the application, where it is right on every deployment.
#
# WHY THIS APPLICATION IN PARTICULAR WANTS ONE. Nearly every string on a
# dashboard arrived from a stranger's browser — paths, referrer hosts, event
# names, custom property keys and their values, UTM parameters. It is all escaped
# and the review found nothing wrong with the escaping. CSP is what decides
# whether the NEXT escaping mistake is an incident or a line in a console. And
# one of the pages rendering those strings is /share/:slug, which has no session,
# no account and no way for a viewer to be warned.
#
# ---------------------------------------------------------------------------
# The four directives with something to explain
#
# `style_src_attr :unsafe_inline` — NOT laziness, and not removable without a
# rewrite. The breakdown bars, the funnel bars and the flow branches all size
# themselves with `style="width: <%= percentage %>%"`. A nonce cannot cover an
# inline style ATTRIBUTE — nonces apply to elements — so the choice is this
# directive or moving every bar to a CSS custom property set the same way, which
# is the same attribute wearing a different name. Kept narrow: `style_src` itself
# stays `:self`, so no <style> block and no injected stylesheet is admitted.
# The numbers interpolated there are `.clamp(0, 100)`ed Floats, not strings.
#
# `script_src` carries a nonce and NOT `:unsafe_inline`. Every inline script in
# the application already emits one: importmap-rails nonces its importmap and
# module tags itself, and the three `tag.script` call sites we own pass
# `content_security_policy_nonce` explicitly. A browser that sees a nonce ignores
# `unsafe-inline` anyway, so listing it would be decoration.
#
# The tracker host is added when it differs from ours. `Tastatur.tracker_url`
# defaults to this instance's own /t.js, but a self-hosted operator may serve it
# from a CDN with TRACKER_URL — and the application layout renders that script
# tag for our own self-measurement. Without this, the one deployment that
# configured a CDN would find its own measurement silently blocked.
#
# THERE IS DELIBERATELY NO `form-action`. The billing buttons POST to us and we
# answer 302 to checkout.stripe.com; some browsers apply form-action to the
# redirect target and some do not, and CLAUDE.md §12 already records what it
# costs when a Stripe hand-off breaks — a button that does nothing, a perfectly
# good redirect in the log, and nothing to alert on. A directive whose behaviour
# differs by browser is not worth pointing at the checkout.
# ---------------------------------------------------------------------------

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri    :self
    policy.object_src  :none
    # Nothing frames this application. Turbo frames are same-document elements,
    # not iframes, so they are unaffected.
    policy.frame_src   :none
    policy.frame_ancestors :self

    # A lambda, not a splat: this file loads before config/initializers/tastatur.rb
    # (initializers run alphabetically), and Rails resolves a Proc source per
    # request. That also means TRACKER_URL is read from the live environment
    # rather than frozen at boot.
    policy.script_src :self, -> { Tastatur.csp_script_origins }
    policy.style_src :self
    # See the note above: the bar widths are style attributes.
    policy.style_src_attr :unsafe_inline

    # `:data` for the inline SVG favicon and any data-URI icon; no remote hosts.
    policy.img_src     :self, :data
    # The flag webfont (see CLAUDE.md §12) is served from here.
    policy.font_src    :self
    # Turbo and Stimulus fetch from this origin only.
    policy.connect_src :self
    policy.manifest_src :self
  end

  # A fresh random nonce per response, NOT the session id.
  #
  # The generated file suggests `request.session.id.to_s`, which is wrong twice
  # here: a nonce that is stable for the life of a session is a nonce an attacker
  # who has seen one page already knows, and reading the session forces a session
  # to exist on requests that would otherwise have none — including
  # /share/:slug, which is served to people with no account.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]

  # REPORT-ONLY UNTIL THE OPERATOR SAYS OTHERWISE, and defaulting that way round
  # is the deliberate part.
  #
  # A CSP that blocks something real is indistinguishable, from the customer's
  # side, from the application being broken — and the failure lands in a console
  # we never see. So a deployment gets a full report-only pass first, and turns
  # enforcement on with CSP_ENFORCE=1 once its own logs are quiet. The header is
  # emitted either way, so the policy is never simply absent.
  #
  # Enforced in development and test, where a violation should stop the person
  # who introduced it rather than be collected.
  config.content_security_policy_report_only =
    Rails.env.production? && ENV.fetch("CSP_ENFORCE", "0") != "1"
end
