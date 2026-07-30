module Admin
  class UserPolicy < BasePolicy
    # The support actions. All of them help somebody who is locked out or stuck,
    # and none of them can read a customer's measurement data.
    def confirm?             = superuser?
    def unlock?              = superuser?
    def resend_confirmation? = superuser?
    def send_password_reset? = superuser?

    # Granting is a superuser action; revoking is too, with one extra rule.
    def grant_admin? = superuser?

    # An admin may not remove their own flag, and the last admin may not be
    # removed at all.
    #
    # Not a courtesy. `admin` is only settable from this screen and from a rake
    # task on the server, so an instance that reaches zero administrators has no
    # way back through the interface — someone has to get shell access to the
    # production container. Losing the console because of a misclick, on the
    # screen whose entire purpose is fixing things, is a bad trade for a
    # restriction nobody needs.
    def revoke_admin?
      return false unless superuser?
      return false if record == context.user
      return false if User.administrators.count <= 1

      true
    end

    class Scope < BasePolicy::Scope
      def resolve
        superuser? ? scope.all : scope.none
      end
    end
  end
end
