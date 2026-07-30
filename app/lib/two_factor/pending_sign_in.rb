module TwoFactor
  # The half-finished sign-in: a password has been accepted, a code has not.
  #
  # WHY THIS EXISTS RATHER THAN A FLAG ON A LIVE SESSION.
  #
  # The obvious implementation is to let Warden complete the sign-in and then
  # block every request with a before_action until the code is entered. It is
  # simpler, and it is wrong here. A Warden session that is merely *gated by a
  # controller callback* is still a fully authenticated session to anything that
  # does not run that callback — and this application mounts Sidekiq::Web with
  # `authenticate :user, ->(u) { u.admin? }`, which is a Warden-level check inside
  # the routes file that no ApplicationController callback can reach. Somebody
  # with a stolen admin password would have walked straight past the second factor
  # into the job console.
  #
  # So the Warden session is torn down completely (see Users::SessionsController)
  # and what remains is this: a small, short-lived marker in a reset session that
  # names who is halfway in. It authorizes nothing. Presenting it does not make
  # `current_user` return anybody.
  #
  # WHAT IS IN IT, AND WHY THE SALT.
  #
  # `salt` is the same authenticatable salt Devise stores in a real session — the
  # first bytes of the encrypted password. Comparing it on the way out means a
  # password changed between the two steps invalidates the pending sign-in, which
  # is the whole point of Devise carrying it. Without it, a password reset
  # performed *because* the password was stolen would not stop the thief finishing
  # a sign-in they had already started.
  #
  # String keys throughout: the session is serialised to JSON in the cookie, so a
  # symbol written here comes back as a string and a symbol lookup would silently
  # miss. Same reason as SelfMeasurement.
  module PendingSignIn
    SESSION_KEY = "two_factor_pending"

    # Ten minutes, matching the life of the code itself. A stash that outlived its
    # code would strand somebody on a screen where every submission fails for a
    # reason the screen cannot see.
    TTL = 10.minutes

    Stash = Struct.new(:user, :remember_me, keyword_init: true)

    def self.write(session, user:, remember_me: false)
      session[SESSION_KEY] = {
        "user_id" => user.id,
        "salt" => user.authenticatable_salt,
        "remember_me" => remember_me,
        "expires_at" => TTL.from_now.to_i
      }
    end

    # The user this session is halfway into signing in as, or nil.
    #
    # Nil for anything that does not add up — no stash, expired, unknown id,
    # changed password, second factor switched off since. Every one of those is
    # answered the same way by the controller (back to the sign-in form), because
    # distinguishing them would tell a caller which of the conditions they had
    # managed to satisfy.
    def self.read(session)
      stash = session[SESSION_KEY]
      return nil if stash.blank?
      return clear(session) if stash["expires_at"].to_i <= Time.current.to_i

      user = User.find_by(id: stash["user_id"])
      return clear(session) if user.nil?
      return clear(session) unless user.two_factor_enabled?

      # `secure_compare` rather than `==`: the salt is derived from the password
      # digest, and a timing oracle on it is a timing oracle on the digest.
      return clear(session) unless Devise.secure_compare(user.authenticatable_salt.to_s, stash["salt"].to_s)

      Stash.new(user: user, remember_me: ActiveModel::Type::Boolean.new.cast(stash["remember_me"]) || false)
    end

    def self.present?(session)
      session[SESSION_KEY].present?
    end

    # Returns nil so the guards above can `return clear(session)` and read as
    # "there is nobody here".
    def self.clear(session)
      session.delete(SESSION_KEY)
      nil
    end
  end
end
