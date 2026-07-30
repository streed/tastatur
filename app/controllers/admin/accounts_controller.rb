module Admin
  # Account-level support actions. Reached from the user page's accounts card —
  # there is deliberately no account index and no account show: the support
  # workflow starts from the person who emailed, and nothing here needs a page
  # that can browse every tenant.
  class AccountsController < BaseController
    # No validation contract: the body is a single enum string, and the check
    # that matters — is this a plan we offer — IS the business rule, made once
    # in Admin::ChangePlan against the catalogue. A contract would be a second
    # copy of that list.
    def update_plan
      account = scoped_accounts.find_by_public_id!(params[:id])
      authorize [:admin, account], :change_plan?

      case Admin::ChangePlan.call(account: account, plan_key: params.dig(:account, :plan))
      in Success(_)
        audit_plan_change(account)
        redirect_back_or_to admin_users_path,
                            notice: "#{account.name} is now on the #{account.billing_plan.name} plan."
      in Failure(:same_plan)
        redirect_back_or_to admin_users_path,
                            notice: "#{account.name} is already on that plan."
      in Failure(:stripe_owns_plan)
        redirect_back_or_to admin_users_path,
                            alert: "The plan for #{account.name} follows its Stripe subscription. " \
                                   "Change the subscription in Stripe; the change arrives by webhook."
      in Failure(:self_hosted)
        redirect_back_or_to admin_users_path,
                            alert: "This install is self-hosted; plans do not apply."
      in Failure(:unknown_plan)
        redirect_back_or_to admin_users_path, alert: "That is not a plan this instance offers."
      end
    end

    private

    def scoped_accounts
      policy_scope([:admin, Account])
    end

    # Same trail as Admin::UsersController: who changed what, findable without
    # anyone having to remember.
    def audit_plan_change(account)
      Rails.logger.info(
        "[admin] #{current_user.email} set plan #{account.plan} on account " \
        "#{account.name.inspect} (#{account.public_id})"
      )
    end
  end
end
