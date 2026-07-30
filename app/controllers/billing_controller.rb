# The plan screen: what you are on, what you have used, and the two buttons that
# change it.
#
# Both buttons hand off to Stripe rather than doing anything themselves — see
# Billing::StartCheckout and Billing::StartPortalSession for why the payment and
# cancellation flows deliberately do not live in this application.
class BillingController < ApplicationController
  # `set_account` first: the gate below has to ask whether THIS account has a
  # subscription to manage, which it cannot do before the account is loaded.
  before_action :set_account
  before_action :ensure_billing_reachable
  before_action :ensure_can_sell, only: %i[checkout]

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

    # False when the screen is open only so an existing subscriber can manage or
    # cancel. The view then renders the portal and nothing else: no allowance, no
    # upgrade, no prices this instance could not charge.
    @can_sell = Tastatur.billing_enabled?
    @usage = Billing::MeasureUsage.call(account: @account).value! if @can_sell
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
      #
      # It is only half of what this hand-off needs, though: the button that posts
      # here must also opt out of Turbo, or the redirect is followed by fetch() and
      # dies on Stripe's CORS policy before the browser ever navigates. Server-side
      # there is nothing to detect it with — this request looks ordinary and the
      # response is a perfectly good 302. See app/views/billing/show.html.erb.
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

  # TWO GATES, because there are two different things this screen does.
  #
  # SELLING is gated on `billing_enabled?`: a self-hosted operator must never meet a
  # paywall in software they are running themselves, and a deployment with no Stripe
  # keys has nothing to offer but a button that cannot work.
  #
  # MANAGING an existing subscription is not. Stripe keeps charging whatever our
  # configuration holds, so an instance that has lost its price id must still let a
  # subscriber cancel or fix a card — gating both on one predicate meant taking the
  # money and removing the cancel button. So the screen stays reachable, read-only,
  # for anyone who has a Stripe customer.
  #
  # The routes exist in every deployment so `billing_path` cannot raise inside a view
  # whose guard someone forgot; these are what make them inert when they should be.
  def ensure_billing_reachable
    return if Tastatur.billing_enabled? || @account.billing_manageable?

    # No record to authorize and no account to authorize it against — the feature
    # itself does not exist here. Stated because CLAUDE.md requires a reason
    # whenever Pundit verification is skipped.
    skip_authorization
    redirect_to sites_path
  end

  # Reached only when the screen is open read-only, i.e. somebody has a subscription
  # to manage on an instance that cannot sell. Posting the form directly is the only
  # way here, since the view renders no upgrade button in that state.
  def ensure_can_sell
    return if Tastatur.billing_enabled?

    skip_authorization
    redirect_to billing_path,
                alert: "New subscriptions are not available on this instance. Your existing " \
                       "subscription is unaffected and can still be managed."
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
