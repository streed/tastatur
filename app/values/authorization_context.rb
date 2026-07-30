# What Pundit authorizes against.
#
# Policies take this rather than a bare User so that "which account is this
# person acting as right now?" is always part of the question. A user can
# belong to several accounts with different roles, and a policy handed only a
# User would have to re-derive the account — which is exactly the kind of step
# that gets forgotten in one policy out of twelve and becomes a cross-tenant
# data leak.
class AuthorizationContext
  attr_reader :user, :account

  def initialize(user:, account:)
    @user = user
    @account = account
  end

  def membership
    @membership ||= user&.membership_for(account)
  end

  def role = membership&.role

  def member? = membership.present?

  def at_least?(minimum)
    membership&.at_least?(minimum) || false
  end

  # Instance-wide superuser (the `admin` flag on User), which is a different
  # thing from being an admin OF an account. Used only for the Sidekiq console.
  def superuser?
    user&.admin? || false
  end
end
