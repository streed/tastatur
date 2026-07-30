class AccountPolicy < ApplicationPolicy
  def show?   = member? && record.id == account&.id
  def update? = at_least?(:admin) && record.id == account&.id

  # Membership management
  def manage_members? = at_least?(:admin) && record.id == account&.id
end
