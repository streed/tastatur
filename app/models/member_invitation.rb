# Form object for the "invite a teammate" form.
#
# The invite form has no ActiveRecord model behind it — it creates a User and a
# Membership, which is the job of Accounts::InviteMember. But a form without a
# model cannot use the shared form builder, and hand-rolled inputs are exactly
# how a codebase accumulates four slightly different forms. So this exists to
# give that one form a model, validation, and the same rendering as every other.
class MemberInvitation
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :email, :string
  attribute :role, :string, default: "member"

  # The roles the INVITER may hand out, supplied by the controller from
  # MembershipPolicy#assignable_roles. Not an ActiveModel attribute: it is a
  # property of the person filling the form in, not of the invitation, and it
  # must never arrive from params — the whole point is that it is not something
  # the submitter gets to state.
  #
  # It defaults to EMPTY rather than to Membership::ROLES. A form object that
  # falls back to "all of them" when the caller forgets to set it is a guard
  # that disappears silently, which is the exact shape of the escalation this
  # was added to close. An unset list refuses every role and the refusal is
  # loud.
  attr_reader :assignable_roles

  def initialize(attributes = {})
    attributes = attributes.to_h.symbolize_keys
    self.assignable_roles = attributes.delete(:assignable_roles)
    super(attributes)
  end

  def assignable_roles=(roles)
    @assignable_roles = Array(roles).map(&:to_s)
  end

  validates :email, presence: true,
                    format: { with: URI::MailTo::EMAIL_REGEXP, message: "is not a valid address" }
  validates :role, inclusion: { in: Membership::ROLES }
  validate :role_is_one_the_inviter_holds

  def normalized_email
    email.to_s.strip.downcase
  end

  private

  # Belt to the controller's braces. The <select> only ever offers what the
  # inviter can grant, and Accounts::MembersController re-checks the posted
  # value against the same policy method — but the error belongs on the form,
  # beside the field, rather than arriving as a flash that loses what was typed.
  #
  # Skipped when the role is already invalid on shape, so a bad value collects
  # one error rather than two saying nearly the same thing.
  def role_is_one_the_inviter_holds
    return unless Membership::ROLES.include?(role.to_s)
    return if assignable_roles.include?(role.to_s)

    errors.add(:role, "is above your own, so it is not yours to give")
  end
end
