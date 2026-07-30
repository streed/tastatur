# A trusted device may be revoked only by the person it was issued to.
#
# Same reasoning as TwoFactorSettingPolicy, and the same deliberate absence of
# the account: a device is a fact about somebody's browser, not about a tenant.
#
# The Scope is not decoration. Revoking is addressed by `public_id`, and looking
# a device up by an unguessable identifier would be *almost* safe on its own —
# almost, which is the wrong amount for the object that decides whether a
# challenge is skipped. Resolving through the scope means a device belonging to
# somebody else raises RecordNotFound before any authorization question is asked,
# which is the same shape SitesController uses for exactly the same reason.
class TrustedDevicePolicy < ApplicationPolicy
  def destroy? = record.present? && user.present? && record.user_id == user.id

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if user.nil?

      scope.where(user_id: user.id)
    end
  end
end
