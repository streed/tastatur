class MembershipPolicy < ApplicationPolicy
  def index?  = member?
  def create? = at_least?(:admin)

  # THE SAME GUARD AS destroy?, AND IT USED TO BE MISSING HERE.
  #
  # This read `at_least?(:admin) && record.account_id == account&.id`, which is
  # two things weaker than it looks. An admin could act on an OWNER's row —
  # which destroy? has always refused — and, because the role being assigned was
  # never checked anywhere, an admin could PATCH their own membership to
  # `owner`. Every membership in the account is inside the policy scope,
  # including the caller's, so that was one request:
  #
  #   PATCH /account/members/:public_id  role=owner  ->  302, role_after=owner
  #
  # Owner is not a cosmetic rung. It gates AccountPolicy#manage_billing?, which
  # is deliberately one rung tighter than everything else because those buttons
  # commit the account to a recurring charge, and SitePolicy#destroy?. So an
  # admin could grant themselves the two powers the role system exists to
  # withhold from them, and nothing on any screen would have said so — the
  # account page renders no role control at all, which is why this survived: it
  # is unreachable through the interface and trivially reachable with curl.
  #
  # Two halves fix it, and both are needed. This predicate answers "may I touch
  # this row at all"; `assignable_roles` below answers "and what may I set it
  # to". Neither alone is sufficient — the first would still let an admin
  # promote a fellow admin, and the second would still let an admin demote an
  # owner to make room.
  def update?
    return false unless record.account_id == account&.id
    return at_least?(:owner) if record.owner?

    at_least?(:admin)
  end

  # An owner may not be removed by an admin, and nobody may remove the last
  # owner — Membership validates the latter, this covers the former.
  def destroy?
    return false unless record.account_id == account&.id
    return at_least?(:owner) if record.owner?

    at_least?(:admin)
  end

  # THE ROLES THIS ACTOR MAY HAND OUT: their own, and everything below it.
  #
  # ONE PLACE SAYS THIS, and three read it — the invite form's <select>, the
  # invite action, and the role change. That is the point. The escalation above
  # existed because "which roles may be granted" was not written down anywhere,
  # so the answer was "all of them" by omission in both of the places that
  # needed one. A list rendered by the view and re-checked by the controller
  # from the same method cannot drift into disagreeing.
  #
  # `at_least?(candidate)` reads backwards for a moment and is right:
  # Membership::ROLES is ordered most- to least-privileged, so "am I at least a
  # candidate?" is exactly "is candidate no higher than me?". An admin gets
  # admin, member and viewer; an owner gets all four.
  def assignable_roles
    return [] unless at_least?(:admin)

    Membership::ROLES.select { |candidate| at_least?(candidate) }
  end

  def may_assign?(role) = assignable_roles.include?(role.to_s)

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if account.nil?

      scope.where(account_id: account.id)
    end
  end
end
