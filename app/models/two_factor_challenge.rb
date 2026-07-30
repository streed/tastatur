# Form object for the two-factor challenge screen.
#
# There is no record behind this form — it submits a code and a preference — and
# a form without a model cannot use the shared builder, which is how a codebase
# ends up with hand-rolled inputs that drift from every other field in the
# application. Same reasoning, and same shape, as MemberInvitation.
#
# It deliberately carries no validations of its own. The code is validated by
# TwoFactorChallengeContract, because this is an unauthenticated endpoint and the
# rule in CLAUDE.md is that external input is checked by a contract at the
# boundary rather than by whatever the form happens to declare. The controller
# copies the contract's messages onto this object so the builder can render them
# in the usual place.
class TwoFactorChallenge
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :code, :string

  # Opt-in, and off by default. A shared or borrowed computer is the case that
  # matters, and a box that is already ticked when the screen loads is one people
  # submit without reading.
  attribute :trust_device, :boolean, default: false
end
