module TwoFactor
  # Judges a submitted code, and consumes it either way.
  #
  # Every exit from here leaves the user in a state the next request can trust:
  # a correct code is destroyed so it cannot be replayed, an exhausted one is
  # destroyed so guessing has to start again from a fresh email, and an expired
  # one is destroyed rather than left to look like a challenge that is still
  # running.
  #
  # THE FOUR FAILURES ARE DISTINCT ON PURPOSE. They are not four ways of saying
  # "no": each one has a different thing for the person to do next, and a single
  # "that did not work" would leave someone retyping a code that expired four
  # minutes ago. None of them discloses anything an attacker does not already
  # know — they are all facts about a challenge issued to a mailbox the caller
  # has already had to name.
  class VerifyChallenge < ApplicationService
    def initialize(user:, code:)
      @user = user
      @code = code
    end

    def call
      return Failure(:no_challenge) if @user.two_factor_code_digest.blank?
      return expire! unless @user.two_factor_challenge_pending?
      return exhaust! if @user.two_factor_failed_attempts >= IssueChallenge::MAX_ATTEMPTS

      return reject! unless @user.authenticate_two_factor_code(@code)

      clear!
      Success(@user)
    end

    private

    def expire!
      clear!
      Failure(:expired)
    end

    # The last attempt is spent, so the code goes with it. Anyone who genuinely
    # mistyped five times can ask for another; anyone grinding has to pay for a
    # fresh email and start the count over, which is what makes five attempts a
    # ceiling rather than a rate.
    def exhaust!
      clear!
      Failure(:too_many_attempts)
    end

    def reject!
      # `increment!` rather than a read-modify-write: two tabs submitting at once
      # would otherwise both read the same count and store the same value, and
      # the budget would quietly become "five per tab".
      @user.increment!(:two_factor_failed_attempts)

      return exhaust! if @user.two_factor_failed_attempts >= IssueChallenge::MAX_ATTEMPTS

      Failure(:invalid)
    end

    # `two_factor_code: nil` goes through has_secure_password's writer, which
    # nils the digest rather than storing a bcrypt hash of the empty string —
    # the difference between "there is no challenge" and "there is a challenge
    # whose answer is blank".
    def clear!
      @user.update!(
        two_factor_code: nil,
        two_factor_code_sent_at: nil,
        two_factor_code_expires_at: nil,
        two_factor_failed_attempts: 0
      )
    end
  end
end
