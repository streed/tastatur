class PagesController < ApplicationController
  skip_before_action :authenticate_user!, only: %i[home]
  # `/` is reachable signed out and renders nothing of its own, so there is no
  # record to authorize. Noted explicitly because CLAUDE.md requires a stated
  # reason whenever Pundit verification is skipped.
  skip_after_action :verify_authorized

  # `/` on a deployment with no marketing site: the sign-in form.
  #
  # THE COMMUNITY EDITION HAS NO LANDING PAGE, and that is a decision rather than
  # an omission. A page arguing for Tastatur has nothing to say to somebody who
  # has already installed it on their own hardware — they made that decision
  # before they got here — and everything such a page would tell them is already
  # somewhere better: what it collects on /privacy, how to install it on /docs,
  # and the version, the licence and who wrote it in the footer of every screen.
  # What is left of a front door on an instance you must sign in to use is the
  # sign-in form, so that is what `/` is.
  #
  # The hosted service's landing page lives in an edition (config/application.rb)
  # and takes over `/` by prepending its own route, so this action never runs
  # there. Nothing here knows that, which is the point: this describes what a
  # deployment does when nothing else claims the path.
  #
  # A REDIRECT, RATHER THAN RENDERING DEVISE'S FORM AT `/`. Routing the root path
  # into the sessions controller — `devise_scope :user { root to:
  # "users/sessions#new" }` — is the tempting one-liner and it misbehaves for
  # everybody who is already signed in. Devise's `require_no_authentication`
  # answers them with the "You are already signed in." alert and a redirect to
  # `signed_in_root_path`, which is `root_path` itself unless a `user_root_path`
  # route exists — so the header logo, which links here from every screen in the
  # application, either loops or scolds somebody who did nothing wrong. Both
  # cases stay silent this way.
  #
  # Deliberately NOT `always_reachable`: on a fresh self-hosted install, sending
  # the operator to the setup wizard is the helpful thing to do.
  def home
    return redirect_to sites_path if user_signed_in?

    redirect_to new_user_session_path
  end

  # `/dashboard` exists because the starter template and Devise's default
  # after-sign-in path both point at it. There is no account-wide dashboard —
  # stats are always per-site — so it forwards to the site list.
  def dashboard
    redirect_to sites_path
  end
end
