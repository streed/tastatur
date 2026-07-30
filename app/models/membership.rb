class Membership < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  # Ordered from most to least privileged; Membership#at_least? relies on the
  # ordering, so do not reorder without updating the policies.
  ROLES = %w[owner admin member viewer].freeze

  belongs_to :account
  belongs_to :user

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :account_id }

  validate :account_retains_an_owner, on: :update

  # The same invariant, on the other way of losing an owner.
  #
  # The validation above only runs `on: :update`, so it caught demoting the last
  # owner and missed deleting them. `DELETE /account/members/:id` therefore left an
  # account with zero owners, which is unrecoverable through the interface: owner
  # is the role that can manage members, so there was nobody left who could
  # appoint a replacement.
  #
  # `prepend: true` so this runs before any dependent-destroy callbacks rather
  # than after they have already begun.
  before_destroy :ensure_account_retains_an_owner, prepend: true

  ROLES.each do |name|
    define_method("#{name}?") { role == name }
  end

  # Role comparison used throughout the Pundit policies:
  #   membership.at_least?(:admin)
  def at_least?(minimum)
    ROLES.index(role.to_s) <= ROLES.index(minimum.to_s)
  end

  private

  # An account with no owner cannot be billed, deleted, or have its members
  # managed — it would be permanently stuck.
  def account_retains_an_owner
    return unless role_changed?(from: "owner")
    return if account.memberships.where(role: "owner").where.not(id: id).exists?

    errors.add(:role, "cannot be changed — an account must always have an owner")
  end

  def ensure_account_retains_an_owner
    return unless owner?

    # The account itself is being deleted and is taking its memberships with it.
    # `destroyed_by_association` is set by Rails only in that case, which is what
    # distinguishes "remove this person" from "remove this whole account" — without
    # it, this guard would make an account with one owner impossible to delete.
    return if destroyed_by_association

    return if account.memberships.where(role: "owner").where.not(id: id).exists?

    errors.add(:base, "An account must always have an owner. Appoint another owner first.")
    throw :abort
  end
end
