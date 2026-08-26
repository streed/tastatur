require "rails_helper"

# The routed half of the escalation. spec/policies/role_escalation_spec.rb pins
# the predicates; this pins that the two ways into them — the role change and
# the invitation — actually consult them.
#
# It matters that this is a request spec and not a policy one. The account page
# renders NO role control at all, so every example below describes a request no
# browser would ever make and anyone can make with curl. That gap is precisely
# where the original bug lived: unreachable through the interface, one line of
# shell away, and invisible to a spec that only drives the form.
RSpec.describe "Member roles", type: :request do
  let(:account) { create(:account) }
  let(:owner) { create(:user, password: "flint-marrow-cadence") }
  let(:admin) { create(:user, password: "flint-marrow-cadence") }

  let!(:owner_membership) { create(:membership, account: account, user: owner, role: "owner") }
  let!(:admin_membership) { create(:membership, account: account, user: admin, role: "admin") }

  describe "PATCH /account/members/:id as an admin" do
    before { sign_in admin }

    it "refuses to promote themselves to owner" do
      patch "/account/members/#{admin_membership.public_id}", params: { role: "owner" }

      expect(admin_membership.reload.role).to eq("admin")
      expect(flash[:alert]).to be_present
    end

    it "refuses to promote somebody else to owner" do
      member = create(:membership, account: account, user: create(:user), role: "member")

      patch "/account/members/#{member.public_id}", params: { role: "owner" }

      expect(member.reload.role).to eq("member")
    end

    it "refuses to touch an owner's membership at all" do
      patch "/account/members/#{owner_membership.public_id}", params: { role: "member" }

      expect(owner_membership.reload.role).to eq("owner")
    end

    it "still allows the changes an admin is meant to make" do
      member = create(:membership, account: account, user: create(:user), role: "member")

      patch "/account/members/#{member.public_id}", params: { role: "viewer" }

      expect(member.reload.role).to eq("viewer")
    end
  end

  describe "PATCH /account/members/:id as an owner" do
    before { sign_in owner }

    it "allows appointing a second owner" do
      patch "/account/members/#{admin_membership.public_id}", params: { role: "owner" }

      expect(admin_membership.reload.role).to eq("owner")
    end
  end

  describe "the invitation form" do
    it "does not offer Owner to an admin" do
      sign_in admin
      get "/account"

      expect(response.body).to include("Admin")
      expect(response.body).not_to match(/<option[^>]*value="owner"/)
    end

    it "offers Owner to an owner" do
      sign_in owner
      get "/account"

      expect(response.body).to match(/<option[^>]*value="owner"/)
    end

    # The form filters; this is the request that skips the form.
    it "refuses an admin inviting somebody straight to owner" do
      sign_in admin

      expect {
        post "/account/members", params: { invitation: { email: "new@example.com", role: "owner" } }
      }.not_to change(Membership.where(role: "owner"), :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "lets an admin invite a member" do
      sign_in admin

      expect {
        post "/account/members", params: { invitation: { email: "new@example.com", role: "member" } }
      }.to change(Membership, :count).by(1)
    end
  end

  # A form object that fell back to "every role" when the caller forgot to
  # supply the list would reintroduce the hole silently. It refuses instead.
  describe MemberInvitation do
    it "grants nothing when the inviter's roles were not supplied" do
      invitation = described_class.new(email: "a@example.com", role: "member")

      expect(invitation).not_to be_valid
      expect(invitation.errors[:role]).to be_present
    end
  end
end
