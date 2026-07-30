class MembershipPolicy < ApplicationPolicy
  def index?  = member?
  def create? = at_least?(:admin)
  def update? = at_least?(:admin) && record.account_id == account&.id

  # An owner may not be removed by an admin, and nobody may remove the last
  # owner — Membership validates the latter, this covers the former.
  def destroy?
    return false unless record.account_id == account&.id
    return at_least?(:owner) if record.owner?

    at_least?(:admin)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if account.nil?

      scope.where(account_id: account.id)
    end
  end
end
