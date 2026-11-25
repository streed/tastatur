# TWO KINDS OF KEY, AND THE LINE BETWEEN THEM IS WHAT THE KEY CAN DO.
#
# A key that WRITES (`write:identify`) is ADMIN-AND-UP, one rung tighter than the
# site settings it lives beside. A key that only READS (`read:analytics`, the one
# given to an AI agent) may be made by ANY member of the account, viewers
# included: it grants nothing its maker cannot already see on the dashboard, and
# it is bound to them (ApiKey#owner_still_member?), so it stops working the
# moment they leave. A member sees and revokes their OWN agent keys; an admin
# sees and revokes all of them.
#
# The rest of this comment is about the write key.
#
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

  # The MCP page: anyone who belongs to the account that owns the site.
  def connect? = member? && same_account?

  # Whether the KEY BEING MADE is a read-only one decides who may make it. The
  # record is what the controller built from the request, so a member cannot ask
  # for a write key by naming it: that key is not `agent?` and falls to the
  # admin rule.
  def create?
    return connect? if agent_key?

    index?
  end
  def new? = create?

  # Revocation is deliberately NOT tighter than creation.
  #
  # The instinct is to make destroying harder than creating, and it is wrong
  # here: a key is revoked when it has leaked, and that is the moment when making
  # somebody find an owner is the expensive thing. Anyone trusted to mint one is
  # trusted to turn one off.
  def destroy?
    return true if index?

    agent_key? && owner? && connect?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if account.nil? || !context.member?

      # Identify keys hang off a site, agent keys off the account itself.
      keys = scope.where(site_id: account.sites.select(:id)).or(scope.where(account_id: account.id))
      return keys if context.at_least?(:admin)

      # Everyone else sees only what they made, and only keys that read.
      keys.where(user_id: user.id)
    end
  end

  private

  def agent_key? = record.respond_to?(:agent?) && record.agent?

  def owner? = record.respond_to?(:user_id) && record.user_id.present? && record.user_id == user&.id

  # Handles being asked about the class (index) as well as a row: a class answers
  # no, so a class-level check never passes by accident.
  def same_account?
    return false unless record.respond_to?(:owning_account_id)

    record.owning_account_id.present? && record.owning_account_id == account&.id
  end
end
