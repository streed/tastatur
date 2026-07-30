class PagesController < ApplicationController
  skip_before_action :authenticate_user!, only: %i[home about]
  # The landing page is genuinely public and touches no records, so there is
  # nothing to authorize. Noted explicitly because CLAUDE.md requires a stated
  # reason whenever Pundit verification is skipped.
  skip_after_action :verify_authorized

  # /about is public information and stays readable before first-run setup, like
  # the other informational pages. The root path deliberately does NOT: on a
  # fresh self-hosted install, sending the operator to the setup wizard is the
  # helpful thing to do.
  always_reachable only: %i[about]

  def about; end

  def home
    # A signed-in visitor almost never wants the marketing page.
    redirect_to sites_path if user_signed_in?
  end

  # `/dashboard` exists because the starter template and Devise's default
  # after-sign-in path both point at it. There is no account-wide dashboard —
  # stats are always per-site — so it forwards to the site list.
  def dashboard
    redirect_to sites_path
  end
end
