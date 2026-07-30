module TwoFactor
  # Turning the second factor on and off, from the account page.
  #
  # Two actions and no `show`: the state is rendered as part of the account
  # screen, next to the login details it belongs with, rather than on a page of
  # its own that nobody would find.
  class SettingsController < ApplicationController
    def create
      authorize current_user, :create?, policy_class: TwoFactorSettingPolicy

      case Enable.call(user: current_user)
      in Success(_)
        redirect_to account_path(anchor: "two-factor"),
                    notice: "Two-factor authentication is on. Your next sign-in will ask for a code."
      in Failure(:already_enabled)
        redirect_to account_path(anchor: "two-factor"), notice: "Two-factor authentication was already on."
      in Failure(:unconfirmed)
        redirect_to account_path(anchor: "two-factor"),
                    alert: "Confirm your email address first — otherwise the codes have nowhere to go."
      end
    end

    def destroy
      authorize current_user, :destroy?, policy_class: TwoFactorSettingPolicy

      case Disable.call(user: current_user)
      in Success(_)
        # Every trusted device went with it, so the cookie on this browser now
        # names a row that no longer exists. Harmless, and cleared anyway: a
        # credential that has been revoked should not be left lying in a browser
        # until it expires on its own.
        device_cookie.delete
        redirect_to account_path(anchor: "two-factor"),
                    notice: "Two-factor authentication is off, and every trusted device was forgotten."
      in Failure(:already_disabled)
        redirect_to account_path(anchor: "two-factor"), notice: "Two-factor authentication was already off."
      end
    end

    private

    def device_cookie
      @device_cookie ||= DeviceCookie.new(cookies, secure: request.ssl?)
    end
  end
end
