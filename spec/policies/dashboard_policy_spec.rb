require "rails_helper"

RSpec.describe DashboardPolicy do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { create(:user) }

  let(:site) { create(:site, account: account) }
  let(:other_site) { create(:site, account: other_account) }

  let(:dashboard) { create(:dashboard, site: site) }
  let(:other_dashboard) { create(:dashboard, site: other_site) }

  def context_for(acct, role: "member")
    create(:membership, account: acct, user: user, role: role) unless user.member_of?(acct)
    AuthorizationContext.new(user: user, account: acct)
  end

  describe "cross-tenant isolation" do
    it "allows a member to read their own account's dashboard" do
      expect(described_class.new(context_for(account), dashboard).show?).to be(true)
    end

    it "denies a dashboard belonging to another account" do
      expect(described_class.new(context_for(account), other_dashboard).show?).to be(false)
      expect(described_class.new(context_for(account), other_dashboard).update?).to be(false)
      expect(described_class.new(context_for(account), other_dashboard).destroy?).to be(false)
    end

    it "denies a non-member entirely" do
      context = AuthorizationContext.new(user: user, account: account)
      expect(described_class.new(context, dashboard).show?).to be(false)
    end

    it "denies a dashboard when the requested account is one the user does not belong to" do
      context = AuthorizationContext.new(user: user, account: other_account)
      expect(described_class.new(context, other_dashboard).show?).to be(false)
    end
  end

  describe "roles" do
    it "lets a viewer read but not create, update or destroy" do
      context = context_for(account, role: "viewer")

      expect(described_class.new(context, dashboard).show?).to be(true)
      expect(described_class.new(context, dashboard).create?).to be(false)
      expect(described_class.new(context, dashboard).update?).to be(false)
      expect(described_class.new(context, dashboard).destroy?).to be(false)
    end

    # Member-level destroy is deliberate even though deletion revokes share
    # links: creating a link (the exposure) stays admin-only in
    # SharedLinkPolicy; removing exposure is the safe direction.
    it "lets a member create, update and destroy" do
      context = context_for(account, role: "member")

      expect(described_class.new(context, dashboard).create?).to be(true)
      expect(described_class.new(context, dashboard).update?).to be(true)
      expect(described_class.new(context, dashboard).destroy?).to be(true)
    end
  end

  describe DashboardPolicy::Scope do
    it "returns only the current account's dashboards" do
      dashboard
      other_dashboard

      scope = described_class.new(context_for(account), Dashboard).resolve
      expect(scope).to contain_exactly(dashboard)
    end

    it "returns nothing when there is no account" do
      dashboard
      context = AuthorizationContext.new(user: user, account: nil)
      expect(described_class.new(context, Dashboard).resolve).to be_empty
    end
  end
end
