# First-boot setup for a self-hosted install.
#
# A fresh self-hosted database has no users, and telling an operator to run
# `rails console` to create one is a poor first impression for software whose
# pitch is "set up in minutes". This creates the owner, their account, and their
# first site in a single form.
#
# It is unreachable once a user exists — Tastatur.needs_first_run_setup? is
# false from then on — so it cannot become a backdoor.
class FirstRunController < ApplicationController
  skip_before_action :authenticate_user!
  skip_after_action :verify_authorized

  before_action :ensure_available

  def show
    @user = User.new
    @site = Site.new(timezone: "Etc/UTC", k_anonymity_threshold: 25)
  end

  def create
    result = Onboarding::FirstRunSetup.call(
      user_params: user_params.to_h.symbolize_keys,
      site_params: site_params.to_h.symbolize_keys
    )

    case result
    in Success(user)
      sign_in(user)
      redirect_to sites_path, notice: "Welcome to Tastatur. Install the snippet to start collecting."
    in Failure(:already_set_up)
      # Somebody else finished setup between this form being opened and being
      # submitted. `ensure_available` cannot catch that — it runs a request
      # earlier — so the service re-checks under a lock and this is what it says
      # when it loses. Deliberately not an error: the instance is set up, which
      # is the outcome the person wanted, and the sign-in form is where they go.
      redirect_to new_user_session_path,
                  notice: "This instance has already been set up. Sign in to continue."
    in Failure(user:, site:)
      @user = user
      @site = site
      render :show, status: :unprocessable_entity
    end
  end

  private

  def ensure_available
    redirect_to root_path unless Tastatur.needs_first_run_setup?
  end

  def user_params
    params.expect(user: %i[email password name])
  end

  def site_params
    params.expect(site: %i[domain timezone k_anonymity_threshold])
  end
end
