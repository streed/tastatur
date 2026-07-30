class FunnelPolicy < ApplicationPolicy
  def show?    = member? && record.site.account_id == account&.id
  def create?  = at_least?(:member)
  def update?  = at_least?(:member) && record.site.account_id == account&.id
  def destroy? = at_least?(:member) && record.site.account_id == account&.id

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if account.nil?

      scope.joins(:site).where(sites: { account_id: account.id })
    end
  end
end
