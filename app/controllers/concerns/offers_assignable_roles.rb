# The roles the current person may hand out, for the two controllers that can
# render the members card.
#
# WHY A CONCERN RATHER THAN A METHOD IN EACH. The invite form lives in
# accounts/show, which AccountsController renders on a plain visit and
# Accounts::MembersController re-renders when an invitation fails validation. A
# <select> whose options differed between those two paths would offer a role on
# one screen and refuse it on the other, which reads as the feature being
# broken. One method, one answer, both templates.
#
# It is a helper_method rather than an ivar for the reason OffersKnownValues
# gives: a create that redirects should not pay for work only a template needs.
# The list itself is MembershipPolicy#assignable_roles — the policy decides, the
# view renders, and the controller re-checks the posted value against the same
# method rather than trusting that the form was the only way in.
module OffersAssignableRoles
  extend ActiveSupport::Concern

  included do
    helper_method :assignable_roles
  end

  private

  def assignable_roles
    return [] if current_account.nil?

    policy(Membership.new(account: current_account)).assignable_roles
  end
end
