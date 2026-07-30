module Users
  # Sign-in, in one step or two.
  #
  # Devise's own controller is unchanged for anybody without two-factor
  # authentication switched on. What is added is the fork after the password is
  # accepted: if this person uses a second factor and this browser is not already
  # trusted, the sign-in is *undone* and held as a pending marker until a code is
  # entered. See TwoFactor::PendingSignIn for why it is undone rather than gated.
  #
  # THE TWO SIDE EFFECTS THAT HAD TO BE MOVED, and what breaks if they are moved
  # back.
  #
  # Warden fires its callbacks the instant the password is accepted, which is no
  # longer the instant somebody signs in. Two of them care:
  #
  #   Devise's :trackable hook increments `sign_in_count` and stamps
  #   `current_sign_in_at`. Left alone, a correct password followed by an
  #   abandoned or failed challenge would be recorded as a sign-in — so the
  #   customer-facing "last signed in" would name a session that never existed,
  #   which is precisely the field somebody reads when they are trying to work
  #   out whether they have been broken into.
  #
  #   The initializer's after_authentication hook records "Signed In" for the
  #   self-measurement funnel, and reads `sign_in_count.to_i.zero?` to tell a
  #   first sign-in from a return. That read only means what it says while it
  #   still runs before trackable.
  #
  # So trackable is suppressed for this request with `devise.skip_trackable` and
  # re-run explicitly at the point sign-in genuinely completes — here when there
  # is no challenge, and in TwoFactor::ChallengesController when there is. The
  # funnel event is written by the hook as before and simply discarded along with
  # the session when a challenge is raised; the challenge controller writes it
  # again when the sign-in actually lands. spec/requests/auth_funnel_spec.rb pins
  # both halves.
  class SessionsController < Devise::SessionsController
    # `prepend_before_action`, so the flag is set before Devise's own
    # `require_no_authentication` and long before the strategy runs. A
    # before_action would be too late for a request that authenticates inside an
    # earlier callback.
    prepend_before_action :suppress_trackable_until_sign_in_completes, only: :create

    def create
      self.resource = warden.authenticate!(auth_options)

      return complete_sign_in unless challenge_required?

      hold_sign_in_for_challenge
    end

    private

    def suppress_trackable_until_sign_in_completes
      request.env["devise.skip_trackable"] = true
    end

    # Only ever asked after the password was accepted, so `resource` is real.
    #
    # A trusted device short-circuits the challenge and is stamped as used, which
    # is the only signal its owner has for spotting one they do not recognise.
    def challenge_required?
      return false unless resource.two_factor_enabled?

      device = device_cookie.device
      return true if device.nil? || device.user_id != resource.id

      device.record_use!
      false
    end

    # The ordinary path, plus the trackable update Devise would have done itself.
    #
    # `sign_in` is called even though Warden already holds the user, exactly as
    # Devise's own create does: when the user is already signed in it does nothing
    # except `expire_data_after_sign_in!`, which drops stale `devise.*` keys — the
    # redirect target a failed authentication left behind, among others.
    def complete_sign_in
      resource.update_tracked_fields!(request)

      set_flash_message!(:notice, :signed_in)
      sign_in(resource_name, resource)
      respond_with resource, location: after_sign_in_path_for(resource)
    end

    # Undo the sign-in, then leave behind only the marker.
    #
    # BOTH STEPS ARE NEEDED, AND THE SECOND IS EASY TO ASSUME AWAY. `sign_out`
    # runs Warden's logout hooks — which is what forgets the remember-me cookie,
    # so a ticked "stay signed in" cannot survive a challenge nobody answered —
    # but `sign_out(scope)` deletes only that scope's keys. Warden resets the
    # session only when logging out of *every* scope, so everything else written
    # during the authenticated moment stays put. That included the "Signed In"
    # funnel event, which then fired on the challenge screen and reported a
    # sign-in that had not happened.
    #
    # ORDER MATTERS: `reset_session` comes before the stash is written, or the
    # stash is thrown away and the challenge screen bounces straight back to the
    # sign-in form with nothing to explain why.
    def hold_sign_in_for_challenge
      user = resource
      remember_me = remember_me_requested?

      sign_out(resource_name)
      reset_session

      TwoFactor::PendingSignIn.write(session, user: user, remember_me: remember_me)
      issue_code(user)

      redirect_to two_factor_challenge_path
    end

    # A failure to send is not a reason to refuse the sign-in outright — the
    # challenge screen has a resend button, and stranding somebody on the sign-in
    # form with "try again" would be a worse answer than letting them reach a
    # screen that can explain itself. `:too_soon` is the ordinary case where a
    # code was already sent moments ago and is still valid.
    def issue_code(user)
      case TwoFactor::IssueChallenge.call(user: user)
      in Success(_) | Failure(:too_soon)
        nil
      in Failure(reason)
        Rails.logger.warn("[tastatur] could not issue a two-factor code: #{reason.inspect}")
      end
    end

    def remember_me_requested?
      ActiveModel::Type::Boolean.new.cast(params.dig(resource_name, :remember_me)) || false
    end

    def device_cookie
      @device_cookie ||= TwoFactor::DeviceCookie.new(cookies, secure: request.ssl?)
    end
  end
end
