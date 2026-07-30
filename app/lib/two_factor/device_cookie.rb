module TwoFactor
  # The browser half of a trusted device.
  #
  # Kept out of the controllers because there are four places that touch it —
  # sign-in reads it, the challenge writes it, disabling two-factor and revoking a
  # device delete it — and a cookie whose flags are spelled out at four call sites
  # is a cookie that ends up with three sets of flags.
  #
  # `cookies.encrypted`, not `signed`: signing would stop the value being *edited*
  # but leave it readable, and the value is a live credential. Encrypting costs
  # nothing here and means a cookie copied out of a browser profile by something
  # that is not a browser is opaque as well as useless without the matching row.
  class DeviceCookie
    NAME = :tastatur_2fa_device

    def initialize(jar, secure:)
      @jar = jar
      @secure = secure
    end

    # The device this browser claims to be, if the claim still stands. Nil covers
    # every failure — no cookie, tampered cookie, revoked row, expired row.
    def device
      TrustedDevice.find_active(@jar.encrypted[NAME])
    end

    def write(credential)
      @jar.encrypted[NAME] = {
        value: credential.token,
        expires: credential.expires_at,
        # No JavaScript in this application reads it, and the one thing an XSS
        # could steal that outlives the session is exactly this.
        httponly: true,
        # `:lax`, not `:strict`. Strict would drop the cookie on a top-level
        # navigation in from an email link, so somebody following "open your
        # dashboard" would be challenged despite having a trusted device — which
        # reads as the feature not working.
        same_site: :lax,
        secure: @secure
      }
    end

    def delete
      @jar.delete(NAME)
    end
  end
end
