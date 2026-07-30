module Admin
  class AccountPolicy < BasePolicy
    # Whether the person may pull the lever at all. Whether the lever can move —
    # Stripe owning the plan, a self-hosted install ignoring the column — is
    # business state, and Admin::ChangePlan answers it with a reason the
    # controller can show. A policy refusal here would render as a bare "not
    # allowed", which for those cases is the wrong explanation.
    def change_plan? = superuser?

    class Scope < BasePolicy::Scope
      def resolve
        superuser? ? scope.all : scope.none
      end
    end
  end
end
