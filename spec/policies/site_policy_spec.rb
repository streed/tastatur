require "rails_helper"

# Cross-tenant isolation is the single most consequential property of a
# multi-tenant analytics product: leaking one customer's traffic to another is
# not a bug report, it is an incident. These examples exist to make that
# impossible to regress quietly.
RSpec.describe SitePolicy do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { create(:user) }

  let(:site) { create(:site, account: account) }
  let(:other_site) { create(:site, account: other_account) }

  def context_for(acct, role: "member")
    create(:membership, account: acct, user: user, role: role) unless user.member_of?(acct)
    AuthorizationContext.new(user: user, account: acct)
  end

  describe "#show?" do
    it "allows a member to read their own account's site" do
      expect(described_class.new(context_for(account), site).show?).to be(true)
    end

    it "denies a site belonging to another account" do
      expect(described_class.new(context_for(account), other_site).show?).to be(false)
    end

    it "denies a non-member entirely" do
      context = AuthorizationContext.new(user: user, account: account)
      expect(described_class.new(context, site).show?).to be(false)
    end

    # The attack this guards against: a user who legitimately belongs to
    # account A passes ?account=<slug of B> and hopes the policy checks only
    # "is this site in the requested account" without checking membership.
    it "denies a site when the requested account is one the user does not belong to" do
      context = AuthorizationContext.new(user: user, account: other_account)
      expect(described_class.new(context, other_site).show?).to be(false)
    end

    # And the mirror image: a real member of B, asking about a site in A.
    it "denies a site from a different account even for a legitimate member" do
      context = context_for(other_account)
      expect(described_class.new(context, site).show?).to be(false)
    end
  end

  describe "roles" do
    it "lets a viewer read but not create" do
      context = context_for(account, role: "viewer")
      expect(described_class.new(context, site).show?).to be(true)
      expect(described_class.new(context, site).create?).to be(false)
    end

    it "requires admin to create a site" do
      expect(described_class.new(context_for(account, role: "member"), site).create?).to be(false)
      user.memberships.update_all(role: "admin")
      expect(described_class.new(AuthorizationContext.new(user: user.reload, account: account), site).create?).to be(true)
    end

    it "requires owner to delete a site" do
      context = context_for(account, role: "admin")
      expect(described_class.new(context, site).destroy?).to be(false)
      user.memberships.update_all(role: "owner")
      expect(described_class.new(AuthorizationContext.new(user: user.reload, account: account), site).destroy?).to be(true)
    end
  end

  describe SitePolicy::Scope do
    it "returns only the current account's sites" do
      site
      other_site
      scope = described_class.new(context_for(account), Site).resolve
      expect(scope).to contain_exactly(site)
    end

    it "returns nothing for a non-member" do
      site
      context = AuthorizationContext.new(user: user, account: account)
      expect(described_class.new(context, Site).resolve).to be_empty
    end

    it "returns nothing when there is no account" do
      site
      context = AuthorizationContext.new(user: user, account: nil)
      expect(described_class.new(context, Site).resolve).to be_empty
    end
  end

  # The base Scope returns `none`, not `all`. A subclass that forgets to
  # override resolve therefore shows an empty page — a visible bug — rather
  # than every tenant's data.
  describe "the default scope is fail-closed" do
    it "resolves to nothing" do
      context = AuthorizationContext.new(user: user, account: account)
      expect(ApplicationPolicy::Scope.new(context, Site).resolve).to be_empty
    end
  end
end
