# Connecting and disconnecting a customer's Stripe account.
#
# ADMIN-AND-UP, and this is the rung that matters most in the revenue feature.
#
# Connecting Stripe does not spend any money, so §14's owner-only rule for
# billing does not apply on its own terms — nothing here commits the account to a
# recurring charge. What it does instead is decide that every member and viewer of
# this account can from now on read the company's revenue. That is a disclosure
# decision about the business, not a preference about a dashboard, and the person
# making it should be the same person who can add and remove the people it
# discloses to. That is exactly the admin rung.
#
# Deliberately NOT owner-only. An owner-only gate on a read-only integration
# would mean the one person who can connect it is often the person least likely
# to be doing the setup, and the predictable outcome is a shared owner login,
# which is worse for everything.
class StripeConnectionPolicy < ApplicationPolicy
  def show? = member? && same_account?

  def create? = at_least?(:admin) && same_account?
  def new? = create?

  # Same rung as connecting, for the reason ApiKeyPolicy gives: disconnecting is
  # the remedy, and a remedy that needs a more senior person than the mistake did
  # is a remedy that arrives late.
  def destroy? = create?

  # Re-running the historical import. Same rung again — it is expensive against
  # the customer's Stripe rate limit and is not something a viewer should be able
  # to trigger repeatedly.
  def backfill? = create?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if account.nil? || !context.member?

      scope.where(site_id: account.sites.select(:id))
    end
  end

  private

  def same_account?
    record.respond_to?(:site) && record.site&.account_id == account&.id
  end
end
