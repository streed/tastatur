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

    # The ordinary path: the trackable update Devise would have done itself, and
    # a session that starts clean.
    #
    # Everything read out of the session is read BEFORE the reset and put back
    # after, which is why this reads as a sequence rather than as three lines.
    # The order below is the whole of it.
    def complete_sign_in
      # Read BEFORE trackable increments the counter it reads. Same ordering
      # note as TwoFactor::ChallengesController, and the same reason.
      first_sign_in = resource.sign_in_count.to_i.zero?
      # CONSUMED BEFORE THE RESET, because it lives in the session. This is the
      # page somebody was trying to reach when they were bounced to the sign-in
      # form, and losing it would land every interrupted visit on the site list
      # instead — a regression nobody would attribute to a security change.
      return_to = stored_location_for(resource_name)

      resource.update_tracked_fields!(request)

      # SESSION FIXATION, and the reason this line was missing is that the
      # two-step path already had it. TwoFactor::ChallengesController resets
      # before signing in, with a comment saying why: the identifier somebody
      # held while they were nobody must not be the one they hold once they are
      # somebody. Every user WITHOUT a second factor came through here, where
      # nothing reset anything. Two sign-in paths that disagree about a
      # hardening step is how one of them stays wrong.
      reset_session

      # AFTER the reset, not before. `reset_session` clears the flash too, so a
      # message set first is a message thrown away.
      set_flash_message!(:notice, :signed_in)

      # `force: true` IS LOAD-BEARING AND ITS ABSENCE IS SILENT. Warden holds
      # the authenticated user in memory on the proxy, not in the session, so it
      # survives `reset_session` — and Devise's `sign_in` short-circuits to "no
      # work needed" when warden already has this user, writing NOTHING back to
      # the freshly emptied session. The result is a request that answers 302 to
      # the dashboard and a browser holding no session at all: correct password,
      # cheerful redirect, straight back to the sign-in form, with nothing
      # logged. Forcing it re-stores the user into the new session.
      sign_in(resource_name, resource, force: true)
      stamp_session_activity

      # Re-recorded, because the Warden hook wrote it into the session the reset
      # just discarded — exactly as the challenge controller re-records it after
      # its own reset. See SelfMeasurement.
      SelfMeasurement.record(session, "Signed In", first_sign_in: first_sign_in)

      respond_with resource, location: return_to || after_sign_in_path_for(resource)
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

    # THE THIRD SIDE EFFECT `devise.skip_trackable` SUPPRESSES, and it is not
    # trackable's.
    #
    # Devise's :timeoutable hook stores `last_request_at` in the warden session
    # — and stores it inside `unless env['devise.skip_trackable']`, sharing the
    # flag this controller sets for an entirely different reason. So the request
    # that signs somebody in leaves no `last_request_at` at all, `timedout?(nil)`
    # is false, and the idle clock does not start until the SECOND authenticated
    # request. A session abandoned immediately after sign-in would never expire.
    #
    # Stamped explicitly here for exactly the reason trackable is re-run
    # explicitly: the flag buys us control over when these happen, and control
    # means doing them, not skipping them. Same in
    # TwoFactor::ChallengesController, which signs people in by the other route.
    def stamp_session_activity
      warden.session(:user)["last_request_at"] = Time.now.utc.to_i
    end

    def remember_me_requested?
      ActiveModel::Type::Boolean.new.cast(params.dig(resource_name, :remember_me)) || false
    end

    def device_cookie
      @device_cookie ||= TwoFactor::DeviceCookie.new(cookies, secure: request.ssl?)
    end
  end
end
