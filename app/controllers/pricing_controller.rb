# The public pricing page.
#
# Deliberately NOT declared `always_reachable`. Where this page does not exist —
# a self-hosted install, or a deployment whose Stripe keys are not set — there is
# nothing to buy, and the only state `always_reachable` would exempt it from is the
# first-run wizard on exactly that kind of install.
#
# Publishing prices an instance cannot charge is worse than publishing none: it is
# an offer that fails at the checkout button.
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
    redirect_to root_path unless Tastatur.billing_enabled?
  end
end
