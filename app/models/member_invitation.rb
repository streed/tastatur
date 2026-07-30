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

  validates :email, presence: true,
                    format: { with: URI::MailTo::EMAIL_REGEXP, message: "is not a valid address" }
  validates :role, inclusion: { in: Membership::ROLES }

  def normalized_email
    email.to_s.strip.downcase
  end
end
