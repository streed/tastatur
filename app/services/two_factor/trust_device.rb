module TwoFactor
  # Issues the credential that lets one browser skip the next thirty days of
  # challenges.
  #
  # Only ever called after a challenge has actually been answered. That ordering
  # is the whole security argument for the feature: the cookie is not a way to
  # avoid proving control of the mailbox, it is a receipt for having proved it.
  class TrustDevice < ApplicationService
    # A browser is one device; a person is not. Without a ceiling, a script that
    # answers one challenge and then loops would mint rows forever, and the
    # revoke screen — the only place this is visible to its owner — would become
    # unreadable at exactly the moment somebody needed to read it.
    MAX_PER_USER = 20

    def initialize(user:)
      @user = user
    end

    def call
      # Expired rows are removed here rather than by a nightly job. This is the
      # only moment the table is written in normal use, the row count per user is
      # tiny, and a sweep that runs when the data is touched cannot silently stop
      # running the way a cron entry can.
      @user.trusted_devices.expired.delete_all

      token = TrustedDevice.new_token
      expires_at = TrustedDevice::TRUST_DURATION.from_now

      @user.trusted_devices.create!(
        token_digest: TrustedDevice.digest_for(token),
        expires_at: expires_at,
        last_used_at: Time.current
      )

      prune_oldest

      Success(DeviceCredential.new(token: token, expires_at: expires_at))
    end

    private

    # Oldest first, and by `created_at` rather than by last use: a device nobody
    # has signed in from since March is the safest one to forget.
    def prune_oldest
      excess = @user.trusted_devices.count - MAX_PER_USER
      return if excess <= 0

      @user.trusted_devices.order(:created_at).limit(excess).destroy_all
    end
  end
end
