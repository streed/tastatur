class SitePolicy < ApplicationPolicy
  # The single rule that prevents cross-tenant reads: a site is visible only if
  # it belongs to the account the user is currently acting as, AND they are a
  # member of that account. Both halves matter — the first alone would let a
  # crafted ?account= parameter through, the second alone would let any member
  # of any account read any site.
  def show?
    member? && record.account_id == account&.id
  end

  def create? = at_least?(:admin)
  def update? = at_least?(:admin) && record.account_id == account&.id
  def destroy? = at_least?(:owner) && record.account_id == account&.id

  # Reading stats is the common case and is open to viewers.
  def stats? = show?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if account.nil? || !context.member?

      scope.where(account_id: account.id)
    end
  end
end
