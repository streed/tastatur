module TwoFactor
  # Turns the second factor off, and takes everything it left behind with it.
  #
  # The three steps are one operation, not three. Clearing the flag alone would
  # leave trusted-device rows that come back to life the moment somebody switches
  # two-factor on again months later — devices they may no longer own, silently
  # skipping the challenge they just asked for. Doing it in a transaction means a
  # failure part-way cannot produce that state either.
  class Disable < ApplicationService
    def initialize(user:)
      @user = user
    end

    def call
      return Failure(:already_disabled) unless @user.two_factor_enabled?

      ActiveRecord::Base.transaction do
        @user.trusted_devices.destroy_all

        @user.update!(
          two_factor_enabled: false,
          two_factor_code: nil,
          two_factor_code_sent_at: nil,
          two_factor_code_expires_at: nil,
          two_factor_failed_attempts: 0
        )
      end

      Success(@user)
    end
  end
end
