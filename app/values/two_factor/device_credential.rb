module TwoFactor
  # What TwoFactor::TrustDevice hands back: the secret to put in the cookie and
  # the moment it stops being accepted.
  #
  # A typed pair rather than a bare string, because the two have to agree.
  # Returning only the token would leave the controller to decide the cookie's
  # lifetime independently of the row's `expires_at`, and the two drifting apart
  # is silent in both directions: a cookie that outlives its row challenges a
  # user who was told they would not be, and a row that outlives its cookie
  # leaves a device trusted in the database that can never present itself.
  class DeviceCredential < Dry::Struct
    # The raw value, shown to the browser once and never recoverable afterwards.
    attribute :token, Types::Strict::String

    attribute :expires_at, Types::Strict::Time
  end
end
