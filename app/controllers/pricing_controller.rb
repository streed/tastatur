# The public pricing page.
#
# Deliberately NOT declared `always_reachable`. On a self-hosted install the page
# does not exist at all — an operator running this on their own hardware has
# nothing to buy — and the only state `always_reachable` would exempt it from is
# the first-run wizard on exactly that kind of install.
class PricingController < ApplicationController
  skip_before_action :authenticate_user!
  # A price list is public information and touches no records, so there is nothing
  # to authorize. Noted explicitly because CLAUDE.md requires a stated reason
  # whenever Pundit verification is skipped.
  skip_after_action :verify_authorized

  before_action :ensure_billing_enabled

  def show
    @plans = Billing::Plan::OFFERED
  end

  private

  def ensure_billing_enabled
    redirect_to root_path if Tastatur.self_hosted?
  end
end
