require "rails_helper"

# How you authenticate is yours, and belongs to no account.
#
# The rest of the policies in this application answer "what may this person do
# inside the account they are acting as". These two deliberately do not consult
# the account at all, and that is the property worth pinning: an owner who could
# reach into a member's second factor could take over a login that also opens
# every OTHER account that person belongs to.
RSpec.describe "Two-factor policies" do
  let(:account) { create(:account) }
  let(:owner) { create(:user) }
  let(:member) { create(:user) }

  before do
    create(:membership, account: account, user: owner, role: "owner")
    create(:membership, account: account, user: member, role: "member")
  end

  def context_for(user)
    AuthorizationContext.new(user: user, account: account)
  end

  describe TwoFactorSettingPolicy do
    it "lets you change your own" do
      policy = described_class.new(context_for(member), member)

      expect(policy.create?).to be(true)
      expect(policy.destroy?).to be(true)
    end

    it "refuses an account owner reaching into a member's" do
      policy = described_class.new(context_for(owner), member)

      expect(policy.create?).to be(false)
      expect(policy.destroy?).to be(false)
    end

    # The instance-wide `admin` flag is not a way in either. There is a support
    # lever for a locked-out person, it can only turn the feature OFF, and it
    # goes through Admin::UserPolicy with an audit line — not through here.
    it "refuses an instance administrator too" do
      superuser = create(:user, :admin)
      create(:membership, account: account, user: superuser, role: "owner")

      policy = described_class.new(context_for(superuser), member)

      expect(policy.create?).to be(false)
    end

    it "refuses when there is nobody signed in" do
      policy = described_class.new(AuthorizationContext.new(user: nil, account: account), member)

      expect(policy.create?).to be(false)
    end
  end

  describe TrustedDevicePolicy do
    it "lets you forget your own device" do
      device = create(:trusted_device, user: member)

      expect(described_class.new(context_for(member), device).destroy?).to be(true)
    end

    it "refuses somebody else's, whatever their role" do
      device = create(:trusted_device, user: member)

      expect(described_class.new(context_for(owner), device).destroy?).to be(false)
    end

    describe described_class::Scope do
      it "returns only your own devices" do
        mine = create(:trusted_device, user: member)
        create(:trusted_device, user: owner)

        expect(described_class.new(context_for(member), TrustedDevice).resolve).to contain_exactly(mine)
      end

      it "returns nothing when there is nobody signed in" do
        create(:trusted_device, user: member)

        scope = described_class.new(AuthorizationContext.new(user: nil, account: nil), TrustedDevice)

        expect(scope.resolve).to be_empty
      end
    end
  end

  describe Admin::UserPolicy do
    let(:superuser) { create(:user, :admin) }

    # The escape hatch, and its deliberate asymmetry: an operator who could turn
    # somebody's second factor ON could point the codes at a mailbox they
    # control, which is a takeover with extra steps.
    it "lets an instance administrator turn two-factor off" do
      context = AuthorizationContext.new(user: superuser, account: nil)

      expect(described_class.new(context, member).disable_two_factor?).to be(true)
    end

    it "gives a non-superuser no such power" do
      context = AuthorizationContext.new(user: owner, account: account)

      expect(described_class.new(context, member).disable_two_factor?).to be(false)
    end

    it "has no way to turn it on" do
      expect(described_class.instance_methods).not_to include(:enable_two_factor?)
      expect(Rails.application.routes.routes.map(&:name).compact)
        .not_to include("enable_two_factor_admin_user")
    end
  end
end
