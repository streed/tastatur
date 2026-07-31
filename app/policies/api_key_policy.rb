# API keys are ADMIN-AND-UP, one rung tighter than the site settings they live
# beside.
#
# A site key measures. An API key writes identity and reads revenue — it is the
# credential that can assert "visitor X is user Y" and can read every customer's
# MRR through the endpoints it authenticates. A viewer who can read a dashboard
# has no business minting one, and a member who can edit a goal has no business
# doing it either.
#
# This is the same reasoning §14 gives for billing being owner-only: the tighter
# rung goes on the action that creates an obligation or hands out a capability,
# not on the action that displays a number.
class ApiKeyPolicy < ApplicationPolicy
  def index? = at_least?(:admin) && same_account?
  def show? = index?
  def create? = index?
  def new? = create?

  # Revocation is deliberately NOT tighter than creation.
  #
  # The instinct is to make destroying harder than creating, and it is wrong
  # here: a key is revoked when it has leaked, and that is the moment when making
  # somebody find an owner is the expensive thing. Anyone trusted to mint one is
  # trusted to turn one off.
  def destroy? = index?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if account.nil? || !context.at_least?(:admin)

      scope.where(site_id: account.sites.select(:id))
    end
  end

  private

  def same_account?
    record_site&.account_id == account&.id
  end

  # Handles being asked about the class (index) as well as a row.
  def record_site
    return nil unless record.respond_to?(:site)

    record.site
  end
end
