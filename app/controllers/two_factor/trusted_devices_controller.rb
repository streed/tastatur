module TwoFactor
  # Revoking devices that may skip the challenge.
  #
  # This is the screen somebody reaches when a laptop was stolen or a machine was
  # handed on, so both actions take effect on the next request rather than the
  # next sign-in: the row is gone, and `TrustedDevice.find_active` stops matching
  # immediately.
  class TrustedDevicesController < ApplicationController
    # Looked up through the scope, not `TrustedDevice.find_by`, so a public_id
    # belonging to somebody else raises RecordNotFound before any authorization
    # question is asked. See TrustedDevicePolicy.
    def destroy
      device = policy_scope(TrustedDevice).find_by_public_id!(params[:public_id])
      authorize device

      revoked_this_browser = device_cookie.device == device
      device.destroy!
      device_cookie.delete if revoked_this_browser

      redirect_to account_path(anchor: "two-factor"), notice: "That device will be asked for a code next time."
    end

    # "Sign out everywhere" for the second factor specifically. Not tied to a
    # single record, so it authorizes the setting rather than a device — the
    # question being asked is about this person's own second factor.
    def destroy_all
      authorize current_user, :destroy?, policy_class: TwoFactorSettingPolicy

      count = current_user.trusted_devices.destroy_all.size
      device_cookie.delete

      redirect_to account_path(anchor: "two-factor"),
                  notice: "#{helpers.pluralize(count, 'device')} forgotten. Every sign-in will ask for a code."
    end

    private

    def device_cookie
      @device_cookie ||= DeviceCookie.new(cookies, secure: request.ssl?)
    end
  end
end
