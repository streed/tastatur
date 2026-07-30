module TwoFactor
  # Mints a one-time code, stores its digest against the user, and emails it.
  #
  # Called at two moments: immediately after a password is accepted, and again
  # when somebody asks for another code. Both go through here so there is exactly
  # one place that decides how long a code lives and how often one may be sent.
  #
  # ISSUING REPLACES. There is never more than one outstanding code, because the
  # alternative — accepting any of the last few — multiplies the guessing surface
  # by the number of times an attacker can make us send mail, which is a number
  # they control. The cost is that requesting a new code invalidates the one
  # already in the reader's inbox, which the screen says out loud.
  class IssueChallenge < ApplicationService
    # Six digits. Long enough that five guesses against a ten-minute code is a
    # 1-in-200,000 proposition, short enough to retype from memory in one go.
    # Anything longer gets copy-pasted, and a code that is always pasted teaches
    # people to paste whatever a convincing email tells them to.
    CODE_LENGTH = 6

    # Ten minutes. Long enough to survive a slow mail relay and a person who goes
    # to make coffee, short enough that a code sitting in an unattended inbox is
    # not a standing key to the account.
    CODE_TTL = 10.minutes

    # How many wrong guesses a single code tolerates before it is destroyed.
    # Deliberately not a lockout: see the migration for why locking the account
    # here would be a denial of service anybody could trigger.
    MAX_ATTEMPTS = 5

    # Nobody needs a second code within twenty seconds of the first, and without
    # this the resend button is a way to make this instance send mail to an
    # arbitrary address as fast as a script can click. Rack::Attack limits the
    # same thing per client; this limits it per account, which is the half a
    # distributed caller could otherwise walk around.
    RESEND_INTERVAL = 20.seconds

    def initialize(user:)
      @user = user
    end

    def call
      return Failure(:not_enabled) unless @user.two_factor_enabled?
      return Failure(:too_soon) if issued_recently?

      code = generate_code

      @user.update!(
        two_factor_code: code,
        two_factor_code_sent_at: Time.current,
        two_factor_code_expires_at: CODE_TTL.from_now,
        two_factor_failed_attempts: 0
      )

      deliver(code)

      Success(@user)
    end

    private

    # `deliver_later`, so a mail provider having a bad minute cannot hang a
    # sign-in that has already succeeded on its first factor. It lands on
    # within_5_seconds, the tier that exists for exactly this: somebody is
    # sitting on the challenge screen waiting for it.
    def deliver(code)
      TwoFactorMailer.challenge(@user, code).deliver_later
    end

    def issued_recently?
      @user.two_factor_code_sent_at.present? &&
        @user.two_factor_code_sent_at > RESEND_INTERVAL.ago
    end

    # `SecureRandom.random_number`, not `rand`, and the leading zero is kept.
    #
    # A code built with `rand(100_000..999_999)` is drawn from a predictable
    # generator and silently throws away a tenth of the keyspace by never
    # starting with 0. Neither shortcut is visible in the output — every code
    # still looks like six digits — which is what makes them worth naming here.
    def generate_code
      SecureRandom.random_number(10**CODE_LENGTH).to_s.rjust(CODE_LENGTH, "0")
    end
  end
end
