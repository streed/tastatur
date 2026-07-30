module TwoFactor
  # The second step of signing in: the emailed code.
  #
  # Nobody is signed in while this controller runs. The only thing the browser
  # carries is the pending marker, which authorizes nothing — see
  # TwoFactor::PendingSignIn for why the Warden session is torn down rather than
  # merely gated. That is also why `authenticate_user!` is skipped here: it is not
  # an exemption from authentication, this is the screen where authentication is
  # still being decided.
  class ChallengesController < ApplicationController
    skip_before_action :authenticate_user!

    # No record and no account, because the premise is that we do not yet know who
    # this is. There is nothing for Pundit to authorize; what stands in for it is
    # `require_pending_sign_in`, which refuses every action here unless a password
    # has already been accepted in this session.
    skip_after_action :verify_authorized

    before_action :require_pending_sign_in

    def show
      @challenge = TwoFactorChallenge.new
      issue_code_if_needed
    end

    def create
      @challenge = TwoFactorChallenge.new(challenge_params)

      validation = TwoFactorChallengeContract.new.call(code: @challenge.code)
      return refuse(validation.errors[:code].to_a) if validation.failure?

      case VerifyChallenge.call(user: pending.user, code: validation[:code])
      in Success(user)
        sign_in_verified(user)
      in Failure(:invalid)
        refuse(["is not correct. #{attempts_remaining_sentence}"])
      in Failure(:too_many_attempts)
        restart("Too many incorrect codes.")
      in Failure(:expired) | Failure(:no_challenge)
        restart("That code has expired.")
      end
    end

    # A fresh code, invalidating whatever is already in the reader's inbox. The
    # screen says so, because a resend that silently kills the code somebody is
    # halfway through typing is worse than no resend button at all.
    def resend
      case IssueChallenge.call(user: pending.user)
      in Success(_)
        redirect_to two_factor_challenge_path,
                    notice: "A new code is on its way. The previous one no longer works."
      in Failure(:too_soon)
        redirect_to two_factor_challenge_path,
                    notice: "A code was just sent. Give it a moment before asking for another."
      in Failure(_)
        redirect_to two_factor_challenge_path, alert: "That code could not be sent. Try again in a moment."
      end
    end

    # "Not you?" — abandons the half-finished sign-in rather than leaving it to
    # time out. Nothing is revoked, because nothing was granted.
    def destroy
      PendingSignIn.clear(session)
      redirect_to new_user_session_path, notice: "Sign-in cancelled."
    end

    private

    def pending
      @pending ||= PendingSignIn.read(session)
    end

    # Every reason a marker can be absent or stale is answered identically, and
    # deliberately: saying which condition failed would confirm that an account
    # exists, or that its password changed a moment ago.
    def require_pending_sign_in
      return if pending.present?

      PendingSignIn.clear(session)
      redirect_to new_user_session_path, alert: "Your sign-in timed out. Please start again."
    end

    # Landing here with no live code — a page reloaded after the code expired, or
    # a tab restored by a browser — quietly issues another rather than showing a
    # form whose every submission is doomed.
    #
    # It can decline: IssueChallenge refuses to send twice within its resend
    # interval, which is reachable by burning every attempt on a code seconds
    # after it was sent. The view reads `@code_outstanding` and says so, rather
    # than showing an input for a code that does not exist.
    def issue_code_if_needed
      IssueChallenge.call(user: pending.user) unless pending.user.two_factor_challenge_pending?

      @code_outstanding = pending.user.two_factor_challenge_pending?
    end

    def sign_in_verified(user)
      remember_me = pending.remember_me

      # Read BEFORE `sign_in`, which runs Devise's trackable hook and increments
      # the very counter this reads. Same ordering note as
      # Users::SessionsController.
      first_sign_in = user.sign_in_count.to_i.zero?

      # Rotates the session id at the moment the session gains privilege, and
      # takes the pending marker with it. Session-fixation hygiene: the
      # identifier somebody held while they were nobody must not be the one they
      # hold once they are somebody.
      reset_session

      user.remember_me = true if remember_me
      sign_in(:user, user)

      trust_this_device(user) if @challenge.trust_device

      # The funnel step the first request recorded and then threw away along with
      # the session. Written here because this — not the password — is the moment
      # the sign-in actually happened. See SelfMeasurement.
      SelfMeasurement.record(session, "Signed In", first_sign_in: first_sign_in)

      redirect_to after_sign_in_path_for(user), notice: "Signed in successfully."
    end

    # `fmap` rather than a `case`: TrustDevice has one outcome, and a one-armed
    # pattern match would raise NoMatchingPatternError the day somebody gives it a
    # second.
    def trust_this_device(user)
      TrustDevice.call(user: user).fmap { |credential| device_cookie.write(credential) }
    end

    # Re-renders the form with the code cleared. Leaving a rejected code in the
    # box invites the identical submission again, and on a five-attempt budget
    # that is a real cost.
    def refuse(messages)
      messages.each { |message| @challenge.errors.add(:code, message) }
      @challenge.code = nil
      @code_outstanding = pending.user.two_factor_challenge_pending?

      render :show, status: :unprocessable_entity
    end

    # The code has been consumed, so the form is reset rather than annotated:
    # there is nothing left to correct. Whether a replacement actually went out
    # decides what the message promises — claiming to have sent one that the
    # resend interval refused is how somebody ends up waiting on an email that is
    # never coming.
    def restart(reason)
      case IssueChallenge.call(user: pending.user)
      in Success(_)
        redirect_to two_factor_challenge_path, alert: "#{reason} We have sent you a new one."
      in Failure(_)
        redirect_to two_factor_challenge_path, alert: "#{reason} Ask for a new one in a moment."
      end
    end

    def attempts_remaining_sentence
      remaining = IssueChallenge::MAX_ATTEMPTS - pending.user.two_factor_failed_attempts

      "#{helpers.pluralize(remaining, 'attempt')} left before we send a new code."
    end

    # `fetch(...).permit`, not `expect`, which is what the rest of the
    # application uses. `expect` raises ParameterMissing when the key is absent
    # or when everything under it is filtered out — and `code[]=1` filters out,
    # because an Array is not a permitted scalar. That turns a request anybody
    # can type into a plain 400 error page on the sign-in path, where the honest
    # answer is the form again saying the code was not six digits.
    def challenge_params
      params.fetch(:two_factor_challenge, {}).permit(:code, :trust_device)
    end

    def device_cookie
      @device_cookie ||= DeviceCookie.new(cookies, secure: request.ssl?)
    end
  end
end
