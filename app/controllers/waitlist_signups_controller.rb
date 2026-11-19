# The public waitlist for a feature that has not shipped.
#
# `skip_authorization` on every action, and here is the documented why (§6):
# there is no record belonging to anybody to authorize against. The subject of
# every action is an email address, and the only credential that could exist for
# it is possession of the mailbox — which is exactly what the token in the link
# proves. Pundit has nothing to add and a policy would be theatre.
class WaitlistSignupsController < ApplicationController
  skip_before_action :authenticate_user!
  skip_after_action :verify_authorized

  # Reachable before first-run setup, like the marketing pages the form is on:
  # a fresh self-hosted install redirecting a waitlist submission to its own
  # setup wizard would be a stranger's address disappearing into somebody
  # else's onboarding.
  always_reachable

  # ONE MESSAGE FOR EVERY OUTCOME, deliberately. Waitlist::Join distinguishes a
  # fresh signup from an address already confirmed and from one mailed a minute
  # ago; saying so would turn this form into a way of asking whether a given
  # person is on the list. Devise's `paranoid` mode makes the same trade, and
  # this form is a good deal more public than that one.
  SENT = "Check your inbox — there is a link to confirm. Nothing is on the list until you click it.".freeze

  def create
    case Waitlist::Join.call(params: signup_params)
    in Success(_)
      redirect_back fallback_location: revenue_path, notice: SENT
    in Failure(validation: errors)
      redirect_back fallback_location: revenue_path,
                    alert: errors[:email]&.first&.upcase_first || "That could not be saved."
    end
  end

  # GET, because it is a link in an email and there is no other kind of link.
  # Being prefetched by a mail client confirms the address, which is the outcome
  # the person was going to produce anyway, so the cost is that the confirmation
  # is occasionally earlier than the click. Contrast `leave` below, where a
  # prefetch would destroy something.
  def confirm
    case Waitlist::Confirm.call(token: params[:token])
    in Success(signup)
      @signup = signup
      @token = params[:token]
      render :confirm
    in Failure(:unknown_token)
      render :expired, status: :not_found
    end
  end

  # The two halves of leaving, and the split is the point. A mail client that
  # prefetches links must not be able to delete somebody's place on the list
  # without them ever seeing the page — so the link in an email lands HERE, on a
  # page with a button, and only the button's DELETE actually removes anything.
  def leave
    @signup = WaitlistSignup.find_by_token(params[:token])
    return render :expired, status: :not_found if @signup.nil?

    @token = params[:token]
  end

  def destroy
    case Waitlist::Leave.call(token: params[:token])
    in Success(_)
      redirect_to revenue_path, notice: "Removed. Your address has been deleted, not just unsubscribed."
    in Failure(:unknown_token)
      render :expired, status: :not_found
    end
  end

  private

  # `feature` is permitted but constrained by the contract and by the CHECK
  # constraint behind it, so a rewritten hidden field lands on a list that
  # exists or on a 422 — never on a new one.
  def signup_params
    params.expect(waitlist_signup: %i[email feature source])
  end
end
