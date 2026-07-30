# The plan screen: what you are on, what you have used, and the two buttons that
# change it.
#
# Both buttons hand off to Stripe rather than doing anything themselves — see
# Billing::StartCheckout and Billing::StartPortalSession for why the payment and
# cancellation flows deliberately do not live in this application.
class BillingController < ApplicationController
  before_action :ensure_billing_enabled
  before_action :set_account

  def show
    authorize @account, :manage_billing?

    # Coming back from a successful checkout, Stripe's webhook and the customer's
    # browser race, and the browser usually wins. Without this the customer lands
    # on a page still saying "Free" seconds after paying, which is the moment they
    # are most likely to think the payment failed and try again.
    #
    # Synchronous, and only on the return from checkout: it is one Stripe API call
    # on a page nobody loads in a loop. The webhook remains the mechanism that
    # matters — this just removes the gap the customer can see.
    sync_after_checkout if params[:checkout] == "success"

    @usage = Billing::MeasureUsage.call(account: @account).value!
  end

  def checkout
    authorize @account, :manage_billing?

    case Billing::StartCheckout.call(
      account: @account,
      success_url: billing_url(checkout: "success"),
      cancel_url: billing_url(checkout: "cancelled")
    )
    in Success(url)
      # `allow_other_host` because the destination is checkout.stripe.com. Rails
      # blocks cross-host redirects by default, which is the right default and the
      # exact case this exception exists for.
      redirect_to url, allow_other_host: true
    in Failure(:already_subscribed)
      redirect_to billing_path, notice: "You are already on this plan."
    in Failure(price_not_configured: variable)
      # A deployment problem, not a customer problem, so it says so plainly rather
      # than blaming the card.
      Rails.logger.error("[tastatur] cannot start checkout: #{variable} is not set")
      redirect_to billing_path, alert: "Payments are not configured on this instance yet."
    in Failure(stripe_error: message)
      redirect_to billing_path, alert: "Stripe could not start the checkout: #{message}"
    in Failure(_)
      redirect_to billing_path, alert: "That plan is not available."
    end
  end

  def portal
    authorize @account, :manage_billing?

    case Billing::StartPortalSession.call(account: @account, return_url: billing_url)
    in Success(url)
      redirect_to url, allow_other_host: true
    in Failure(:no_customer)
      redirect_to billing_path, notice: "There is nothing to manage yet — this account has never been billed."
    in Failure(stripe_error: message)
      redirect_to billing_path, alert: "Stripe could not open the billing portal: #{message}"
    in Failure(_)
      redirect_to billing_path, alert: "The billing portal is not available."
    end
  end

  private

  # A self-hosted operator must never meet a paywall in software they are running
  # themselves. The routes exist in every deployment so `billing_path` cannot raise
  # inside a view whose guard someone forgot; this is what makes them inert.
  def ensure_billing_enabled
    return unless Tastatur.self_hosted?

    # No record to authorize and no account to authorize it against — the feature
    # itself does not exist here. Stated because CLAUDE.md requires a reason
    # whenever Pundit verification is skipped.
    skip_authorization
    redirect_to sites_path
  end

  def set_account
    @account = current_account
    raise ActiveRecord::RecordNotFound if @account.nil?
  end

  # Nothing is shown if this fails. The webhook is the authority and will arrive
  # regardless; reporting an error here would tell a customer whose payment
  # succeeded that something went wrong, which is both alarming and untrue.
  def sync_after_checkout
    Billing::SyncSubscription.call(account: @account)
  end
end
