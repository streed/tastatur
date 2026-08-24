# A campaign is the heading its links live under, so it carries exactly the
# permissions its links do — see CampaignLinkPolicy, whose reasoning this
# mirrors and must not diverge from. Destroying one takes its links with it and
# still destroys no measurement: the events keep their UTM values, and every row
# reappears under "Campaigns not built here" rather than disappearing.
class CampaignPolicy < ApplicationPolicy
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
