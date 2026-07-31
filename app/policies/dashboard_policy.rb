# Same shape as FunnelPolicy: dashboards are member-level content, not
# account administration.
#
# destroy? is member-level even though deleting a dashboard also revokes any
# share links pointing at it (Dashboard has_many :shared_links, dependent:
# :destroy). That is deliberate: the EXPOSURE decision — creating a link — is
# admin-only in SharedLinkPolicy and stays there; removing exposure is the
# safe direction, the same asymmetry as §16's "least of all for getting out".
class DashboardPolicy < ApplicationPolicy
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
