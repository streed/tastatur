# Same shape as GoalPolicy, and for the same reason: a campaign link belongs to
# a site, so every predicate has to check the site's account as well as the
# role. Deleting one is member-and-up rather than admin-and-up because it
# destroys no measurement — the events keep their UTM values and the report row
# survives as an unsaved campaign.
class CampaignLinkPolicy < ApplicationPolicy
  def index?   = member?
  def show?    = member? && own?
  def create?  = at_least?(:member)
  def update?  = at_least?(:member) && own?
  def destroy? = at_least?(:member) && own?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if account.nil?

      scope.joins(:site).where(sites: { account_id: account.id })
    end
  end

  private

  def own? = record.site.account_id == account&.id
end
