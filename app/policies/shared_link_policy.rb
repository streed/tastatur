class SharedLinkPolicy < ApplicationPolicy
  # Creating a public link exposes a tenant's stats to anyone holding the URL,
  # so it is an admin decision rather than something any member can do.
  def index?   = member?
  def create?  = at_least?(:admin)
  def destroy? = at_least?(:admin) && record.site.account_id == account&.id

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if account.nil?

      scope.joins(:site).where(sites: { account_id: account.id })
    end
  end
end
