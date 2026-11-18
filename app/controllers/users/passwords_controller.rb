module Users
  # Devise's passwords controller, subclassed for exactly one reason: to count
  # the far end of a password reset from the server.
  #
  # The view used to carry `data-analytics-event="Password Reset Completed"` on
  # the form, reported by the analytics Stimulus controller from
  # `turbo:submit-end`. That form now opts out of Turbo so a password manager can
  # offer to update the password somebody just set — a Turbo submission is a
  # `fetch` and produces no navigation, and a manager with a stale password saved
  # is a lockout waiting to happen on the very screen this flow exists to undo.
  # `turbo:submit-end` does not fire on a form that has opted out, so the metric
  # had to move or be silently lost.
  #
  # The server is the better place for it regardless: it is the only party that
  # knows the token was still valid AND the new password was accepted, which is
  # precisely what makes this figure worth having against
  # "Password Reset Requested" — how many people the emailed link actually got
  # back in. Same mechanism as "Signed In" and "Account Created".
  # See SelfMeasurement.
  class PasswordsController < Devise::PasswordsController
    private

    # Devise calls this on the success branch of `update` and nowhere else, so
    # an expired token or a rejected confirmation never reaches it. That is the
    # whole reason the hook is used rather than a block around `super`, which
    # would run either way.
    #
    # Devise signs the user in from here, and that sign-in is deliberately NOT
    # counted as one: it is the recovery path, not the funnel. The note the view
    # used to carry said so, and moving the event must not quietly change what it
    # means.
    def after_resetting_password_path_for(resource)
      SelfMeasurement.record(session, "Password Reset Completed")
      super
    end
  end
end
