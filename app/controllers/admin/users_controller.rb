module Admin
  # The support desk: find the person who emailed us, and unstick them.
  #
  # Every action here is something a customer could do themselves if they were not
  # locked out, unconfirmed, or unable to receive our mail. None of them reads a
  # customer's measurement data, and there is deliberately no "sign in as this
  # user" — impersonation would hand an administrator every dashboard on the
  # instance, which is precisely what the rest of this codebase is arranged to
  # make impossible.
  class UsersController < BaseController
    before_action :set_user, except: :index

    def index
      @query = params[:q]
      @users = scoped_users.matching(@query).by_recency.includes(:accounts).limit(100)
    end

    def show
      authorize [:admin, @user], :show?
      @accounts = @user.accounts.includes(:sites).order(:created_at)
    end

    # Devise's confirmable, done on the customer's behalf. The usual reason is
    # that the confirmation mail bounced or landed in spam, and the person is
    # sitting at a sign-in screen that will not let them in.
    def confirm
      authorize [:admin, @user], :confirm?

      if @user.confirmed?
        redirect_back_to_user notice: "#{@user.email} was already confirmed."
      else
        @user.confirm
        audit("confirmed email for", @user)
        redirect_back_to_user notice: "Confirmed #{@user.email}."
      end
    end

    # Lockable locks after repeated failed sign-ins. Waiting out the unlock period
    # is the alternative, and telling a paying customer to come back later is not
    # a support answer.
    def unlock
      authorize [:admin, @user], :unlock?

      if @user.locked?
        @user.unlock_access!
        audit("unlocked", @user)
        redirect_back_to_user notice: "Unlocked #{@user.email}."
      else
        redirect_back_to_user notice: "#{@user.email} was not locked."
      end
    end

    def resend_confirmation
      authorize [:admin, @user], :resend_confirmation?

      if @user.confirmed?
        redirect_back_to_user alert: "#{@user.email} is already confirmed."
      else
        @user.send_confirmation_instructions
        audit("resent confirmation to", @user)
        redirect_back_to_user notice: "Confirmation email sent to #{@user.email}."
      end
    end

    # Sends the ordinary reset email. It does NOT set a password: an administrator
    # who can choose someone's password can sign in as them, and the token goes to
    # the address on file so the person who receives it is the person who owns it.
    def send_password_reset
      authorize [:admin, @user], :send_password_reset?

      @user.send_reset_password_instructions
      audit("sent a password reset to", @user)
      redirect_back_to_user notice: "Password reset email sent to #{@user.email}."
    end

    # The escape hatch for two-factor authentication, and the reason
    # TwoFactor::Enable can skip an enrolment challenge.
    #
    # Codes go to the address on the account. When that mailbox stops working —
    # an employer's domain expiring, a provider closing an account — the person
    # is locked out by a control they switched on themselves, and every remedy
    # inside the product requires signing in first. Without this the only fix is
    # a Rails console on a production container.
    #
    # It can only turn the feature OFF. An administrator who could turn it on
    # could aim somebody's codes at a mailbox of their choosing, which is a
    # takeover with extra steps. Trusted devices go with it (see
    # TwoFactor::Disable), so this cannot be used to leave a browser
    # pre-authorised either.
    def disable_two_factor
      authorize [:admin, @user], :disable_two_factor?

      case TwoFactor::Disable.call(user: @user)
      in Success(_)
        audit("disabled two-factor authentication for", @user)
        redirect_back_to_user notice: "Two-factor authentication is off for #{@user.email}."
      in Failure(:already_disabled)
        redirect_back_to_user notice: "#{@user.email} was not using two-factor authentication."
      end
    end

    def grant_admin
      authorize [:admin, @user], :grant_admin?

      @user.update!(admin: true)
      audit("granted instance admin to", @user)
      redirect_back_to_user notice: "#{@user.email} is now an instance administrator."
    end

    def revoke_admin
      authorize [:admin, @user], :revoke_admin?

      @user.update!(admin: false)
      audit("revoked instance admin from", @user)
      redirect_back_to_user notice: "#{@user.email} is no longer an instance administrator."
    end

    private

    def set_user
      @user = scoped_users.find_by_public_id!(params[:id])
    end

    # Administrative actions on someone else's account leave a trace. Lograge ships
    # these to the same place as everything else, so "who unlocked this account"
    # has an answer that does not depend on anyone remembering.
    def audit(verb, user)
      Rails.logger.info(
        "[admin] #{current_user.email} #{verb} #{user.email} (#{user.public_id})"
      )
    end

    def redirect_back_to_user(**flash_args)
      redirect_to admin_user_path(@user), **flash_args
    end
  end
end
