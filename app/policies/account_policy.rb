class AccountPolicy < ApplicationPolicy
  def show?   = member? && record.id == account&.id
  def update? = at_least?(:admin) && record.id == account&.id

  # Membership management
  def manage_members? = at_least?(:admin) && record.id == account&.id

  # Billing is OWNER ONLY, one rung tighter than everything else here.
  #
  # The two buttons on that screen commit the account to a recurring charge and
  # can cancel it. An admin can already do everything else — invite people, change
  # retention, delete a site — because those are operational. Spending someone
  # else's money is not, and "an admin cancelled our subscription" is not a
  # mistake that can be undone by re-reading a policy.
  #
  # The `record.id == account&.id` half is the same cross-tenant guard as above and
  # matters just as much: without it a member of account A could open the billing
  # screen of account B by switching the slug.
  def manage_billing? = at_least?(:owner) && record.id == account&.id
end
