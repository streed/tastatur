require "rails_helper"

# THE SPEC THAT WOULD HAVE CAUGHT IT.
#
# MembershipPolicy#update? once read `at_least?(:admin) && same account`, with
# nothing anywhere checking WHICH role was being assigned. An account admin
# could therefore PATCH their own membership to `owner` and inherit
# AccountPolicy#manage_billing? — the one predicate deliberately kept a rung
# tighter than everything else, because those buttons commit the account to a
# recurring charge.
#
# Every individual policy had a spec. What was missing was a spec that asks the
# same question of every role at once, which is the only shape that notices when
# one predicate is more generous than the sibling beside it. So this is a matrix
# rather than a list of examples: adding a role to Membership::ROLES without
# deciding what it may hand out fails here.
RSpec.describe "Role escalation" do
  let(:account) { create(:account) }

  def context_for(role)
    user = create(:user)
    create(:membership, account: account, user: user, role: role)
    AuthorizationContext.new(user: user, account: account)
  end

  def membership_with(role)
    create(:membership, account: account, user: create(:user), role: role)
  end

  # Ordered most- to least-privileged, exactly as Membership::ROLES is.
  GRANTABLE = {
    "owner" => %w[owner admin member viewer],
    "admin" => %w[admin member viewer],
    "member" => [],
    "viewer" => []
  }.freeze

  it "covers every role the application defines" do
    expect(GRANTABLE.keys).to match_array(Membership::ROLES)
  end

  describe "which roles an actor may hand out" do
    GRANTABLE.each do |actor_role, grantable|
      it "lets #{actor_role} grant #{grantable.presence&.join(', ') || 'nothing'}" do
        policy = MembershipPolicy.new(context_for(actor_role), membership_with("member"))

        expect(policy.assignable_roles).to eq(grantable)
      end

      (Membership::ROLES - grantable).each do |refused|
        it "refuses to let #{actor_role} grant #{refused}" do
          policy = MembershipPolicy.new(context_for(actor_role), membership_with("member"))

          expect(policy.may_assign?(refused)).to be(false)
        end
      end
    end
  end

  # The other half. Bounding what may be GRANTED is not enough on its own: an
  # admin who could still edit an owner's row would simply demote the owner to
  # make the seat free.
  describe "whose row may be touched" do
    it "refuses an admin acting on an owner's membership" do
      policy = MembershipPolicy.new(context_for("admin"), membership_with("owner"))

      expect(policy.update?).to be(false)
      expect(policy.destroy?).to be(false)
    end

    it "allows an owner acting on an owner's membership" do
      policy = MembershipPolicy.new(context_for("owner"), membership_with("owner"))

      expect(policy.update?).to be(true)
    end

    it "allows an admin acting on a member's membership" do
      policy = MembershipPolicy.new(context_for("admin"), membership_with("member"))

      expect(policy.update?).to be(true)
    end

    it "refuses a member acting on anybody" do
      policy = MembershipPolicy.new(context_for("member"), membership_with("viewer"))

      expect(policy.update?).to be(false)
    end

    # The record is in another account entirely. The scope should already have
    # excluded it, so this is the belt to that brace.
    it "refuses any actor acting on another account's membership" do
      elsewhere = create(:membership, account: create(:account), user: create(:user), role: "member")
      policy = MembershipPolicy.new(context_for("owner"), elsewhere)

      expect(policy.update?).to be(false)
      expect(policy.destroy?).to be(false)
    end
  end
end
