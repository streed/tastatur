# Reading the customer list and the revenue attached to it.
#
# OPEN TO VIEWERS, like every other report in this product. The instinct is to
# put revenue behind a tighter rung than traffic, and it is the wrong call: the
# entire premise of this feature is that the person choosing where to spend the
# marketing budget can see which channel produced paying customers. A viewer role
# that can see 40,000 visitors and not the £3 they were worth is a role that
# sends someone back to a spreadsheet.
#
# The place the tighter rung genuinely belongs is on CONNECTING Stripe, which is
# what decides whether this data exists in the account at all — see
# StripeConnectionPolicy.
#
# WHAT THIS DOES NOT COVER: public shared dashboards. Those authorize nothing and
# reach none of this — SharedDashboardsController renders traffic only, and
# Revenue::AttributionReport is never called from it. Publishing a company's MRR
# to an unguessable-but-public URL is not a setting anybody should be one
# checkbox away from.
class CustomerPolicy < ApplicationPolicy
  def index? = member? && same_account?
  def show? = index?

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
