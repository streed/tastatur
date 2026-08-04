class PagesController < ApplicationController
  skip_before_action :authenticate_user!, only: %i[home]
  # The landing page is genuinely public and touches no records, so there is
  # nothing to authorize. Noted explicitly because CLAUDE.md requires a stated
  # reason whenever Pundit verification is skipped.
  skip_after_action :verify_authorized

  # The community edition's landing page: what this software is, who wrote it,
  # what it refuses to collect, and where the documentation is.
  #
  # It is NOT a marketing page and should not become one. A page arguing for a
  # hosted service has nothing to say to somebody who has already installed this
  # on their own hardware — they made that decision before they got here. The
  # hosted service's landing page lives in an edition (config/application.rb) and
  # takes over `/` by prepending its own route.
  #
  # HTML only, deliberately. The marketing page has a markdown rendering because
  # its job is to be read by machine readers deciding whether to adopt the
  # product; this page's job is done by /docs, which has one.
  #
  # Deliberately NOT `always_reachable`: on a fresh self-hosted install, sending
  # the operator to the setup wizard is the helpful thing to do.
  def home
    redirect_to sites_path if user_signed_in?
  end

  # `/dashboard` exists because the starter template and Devise's default
  # after-sign-in path both point at it. There is no account-wide dashboard —
  # stats are always per-site — so it forwards to the site list.
  def dashboard
    redirect_to sites_path
  end
end
