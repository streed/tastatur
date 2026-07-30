class SitePolicy < ApplicationPolicy
  # The single rule that prevents cross-tenant reads: a site is visible only if
  # it belongs to the account the user is currently acting as, AND they are a
  # member of that account. Both halves matter — the first alone would let a
  # crafted ?account= parameter through, the second alone would let any member
  # of any account read any site.
  def show?
    member? && record.account_id == account&.id
  end

  # Admin-and-up, AND a confirmed email address.
  #
  # WHY THE SECOND HALF IS HERE RATHER THAN LEFT TO DEVISE. Today it is belt and
  # braces: `allow_unconfirmed_access_for = 0.days` means an unconfirmed user
  # cannot hold a session at all, so this condition is unreachable through the
  # sign-in form. That is exactly why it is worth writing down — the guarantee
  # currently rests on one number in an initializer, and relaxing it (a very
  # ordinary thing to want, so new users can look around before confirming)
  # would silently open site creation to anybody who can type an address they do
  # not own.
  #
  # A site is the thing that turns an account into a load-bearing part of
  # somebody else's website: it mints a public token, it starts accepting
  # traffic, and it commits us to storing and serving that traffic. Doing all of
  # that for an address nobody has proved they can read is how an instance
  # accumulates abandoned sites and how a stranger's domain ends up measured
  # under an email that was never theirs.
  #
  # Reading and deleting are deliberately NOT gated. Confirmation is a
  # precondition for creating an obligation, not for looking at what you already
  # have — and locking somebody out of deleting their own data because of an
  # unconfirmed address would be the wrong answer in the one case where they
  # most want out.
  def create? = at_least?(:admin) && user&.confirmed?
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
