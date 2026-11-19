module Users
  class RegistrationsController < Devise::RegistrationsController
    before_action :ensure_signup_allowed, only: %i[new create]
    before_action :configure_permitted_parameters

    # Devise yields the resource after it is built and saved, which is where a
    # new user gets the account they will own. Doing it here rather than in a
    # User callback keeps the side effect visible and testable, per the
    # architectural rules in CLAUDE.md.
    def create
      super do |user|
        next unless user.persisted?

        # RECORDED HERE RATHER THAN ON THE FORM, for the reason the signup view
        # gives: the form opts out of Turbo so a password manager can offer to
        # save the password, and `turbo:submit-end` — which is what reported
        # this — never fires again. The server is the better place for it
        # anyway; it is the only party that knows the sign-up was accepted.
        # Same mechanism as "Signed In". See SelfMeasurement.
        SelfMeasurement.record(session, "Account Created")

        Onboarding::ProvisionAccount.call(user: user)
        # Enqueued rather than sent inline, and after the account exists so the
        # notification can name it. A mail server having a bad minute must not be
        # able to fail a signup that has already succeeded.
        NotifyAdminsOfSignupJob.perform_later(user.id)
      end
    end

    # Devise's default `update_resource` calls `update_with_password`, which
    # demands the current password for EVERY update — including changing only
    # your display name. That is a poor trade: it adds a password prompt to a
    # harmless edit, and it contradicts what the form tells the user, which is
    # that the current password is needed for an email or password change.
    #
    # So the requirement is applied to exactly the two fields that warrant it.
    # Both are credential changes an attacker with a stolen session would want:
    # a new password locks the owner out, and a new email address redirects
    # password resets to the attacker.
    def update_resource(resource, params)
      changing_password = params[:password].present? || params[:password_confirmation].present?
      changing_email = params[:email].present? && params[:email] != resource.email

      return super if changing_password || changing_email

      params.delete(:current_password)
      resource.update_without_password(params.except(:password, :password_confirmation))
    end

    private

    # Login details are edited from the account page, so a successful save
    # returns there rather than to Devise's default (the signed-in root, which
    # would bounce the user to their site list and look like the form was
    # ignored).
    #
    # ALSO WHERE THE UPDATE IS COUNTED, and this hook specifically because Devise
    # calls it on the success branch and nowhere else — `update` yields the
    # resource whether or not it saved, so a block there would count a rejected
    # current password as a change of something. The event used to come from
    # `turbo:submit-end` on the form itself, which no longer fires now that the
    # form opts out of Turbo for password managers. See SelfMeasurement.
    def after_update_path_for(_resource)
      SelfMeasurement.record(session, "Login Details Updated")
      account_path
    end

    # Devise's default sanitizer permits only email and password, so `name`
    # would be silently dropped from the signup form.
    def configure_permitted_parameters
      devise_parameter_sanitizer.permit(:sign_up, keys: [:name])
      devise_parameter_sanitizer.permit(:account_update, keys: [:name])
    end

    def ensure_signup_allowed
      return if Tastatur.allow_signup?

      redirect_to new_user_session_path, alert: signup_closed_message
    end

    # ONE SWITCH, TWO DIFFERENT FACTS. ALLOW_SIGNUP=0 on somebody's own install
    # means "this instance is theirs, ask them" — there is nothing to wait for
    # and telling a stranger to wait would be a lie. On the hosted service it
    # means "not yet". Switched on `Tastatur.waitlist_enabled?`, which is false
    # exactly when the instance is self-hosted.
    def signup_closed_message
      if Tastatur.waitlist_enabled?
        "Signups are not open yet."
      else
        "Registration is closed on this instance. Ask an administrator for an invitation."
      end
    end
  end
end
