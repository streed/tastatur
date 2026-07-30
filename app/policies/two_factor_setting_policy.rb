# Who may turn a second factor on or off: its owner, and nobody else.
#
# The record is a User, and the only question asked is whether it is the *same*
# user as the one making the request. Note what is deliberately absent: the
# account, the membership, and the role. An account owner may remove somebody
# from their account, change their role, and cancel the subscription — and may
# not touch how that person authenticates, because their login is theirs and
# belongs to every other account they are a member of too.
#
# An instance administrator is not an exception here either. The admin console
# can turn two-factor OFF for somebody locked out of their own mailbox (see
# Admin::UserPolicy#disable_two_factor?), which is a support action with an audit
# line; it cannot turn it on, and it does not route through this policy.
class TwoFactorSettingPolicy < ApplicationPolicy
  def create?  = own?
  def destroy? = own?

  private

  def own?
    record.present? && user.present? && record == user
  end
end
