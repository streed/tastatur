require "rails_helper"

# The admin console: who can reach it, and what it refuses to show.
#
# `admin` on User is the instance-wide operator flag, which is a DIFFERENT thing
# from being an admin of an account. The distinction is the whole reason these
# policies live under Admin:: and do not inherit from ApplicationPolicy, so it is
# the first thing tested here.
RSpec.describe "Admin console", type: :request do
  let(:admin) { create(:user, admin: true) }
  let(:regular) { create(:user) }

  # An owner of their own account, with the highest possible membership role.
  # This is the person the namespace exists to keep out: being an admin OF an
  # account must confer nothing over the instance.
  let(:account_owner) do
    create(:user).tap do |user|
      account = create(:account)
      create(:membership, account: account, user: user, role: "owner")
    end
  end

  ADMIN_PATHS = %w[/admin /admin/users /admin/sites].freeze

  describe "access" do
    it "lets an instance administrator in" do
      sign_in admin
      ADMIN_PATHS.each do |path|
        get path
        expect(response).to have_http_status(:ok), "expected #{path} to be reachable"
      end
    end

    it "turns away a signed-in user without the flag" do
      sign_in regular
      ADMIN_PATHS.each do |path|
        get path
        expect(response).to have_http_status(:redirect), "expected #{path} to be refused"
      end
    end

    # The case the namespace exists for.
    it "turns away the owner of an account" do
      sign_in account_owner
      ADMIN_PATHS.each do |path|
        get path
        expect(response).to have_http_status(:redirect), "expected #{path} to be refused to an account owner"
      end
    end

    it "turns away an anonymous visitor" do
      ADMIN_PATHS.each do |path|
        get path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    # Every member action, not just the pages. A gate on the index that leaves the
    # POSTs open is the usual shape of this mistake.
    it "refuses every support action to a non-admin" do
      sign_in regular
      target = create(:user)

      [[:post, confirm_admin_user_path(target)],
       [:post, unlock_admin_user_path(target)],
       [:post, resend_confirmation_admin_user_path(target)],
       [:post, send_password_reset_admin_user_path(target)],
       [:post, grant_admin_admin_user_path(target)],
       [:delete, revoke_admin_admin_user_path(target)]].each do |verb, path|
        public_send(verb, path)
        expect(response).to have_http_status(:redirect), "expected #{verb.upcase} #{path} to be refused"
        expect(target.reload.admin).to be(false)
      end
    end
  end

  describe "the overview" do
    before { sign_in admin }

    it "renders with no data at all" do
      get "/admin"
      expect(response).to have_http_status(:ok)
    end

    it "counts the instance" do
      create_list(:user, 2)
      get "/admin"

      expect(response.body).to include("Accounts")
      expect(response.body).to include("Signups")
    end

    # Redis being down is exactly when an operator opens this page. A console that
    # 500s in that state is useless precisely when it is needed.
    it "still renders when Redis is unreachable" do
      allow(Ingest::WriteBuffer).to receive(:depth).and_raise(Redis::CannotConnectError)
      allow(Sidekiq::Queue).to receive(:all).and_raise(Redis::CannotConnectError)

      get "/admin"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("unreachable")
    end
  end

  describe "finding people" do
    before { sign_in admin }

    it "matches on a partial email" do
      create(:user, email: "wanted@example.com")
      create(:user, email: "someone-else@example.com")

      get "/admin/users", params: { q: "wanted" }

      expect(response.body).to include("wanted@example.com")
      expect(response.body).not_to include("someone-else@example.com")
    end

    it "says so when nothing matches" do
      get "/admin/users", params: { q: "nobody" }
      expect(response.body).to include("Nobody matches")
    end
  end

  describe "support actions" do
    before { sign_in admin }

    let(:target) { create(:user, confirmed_at: nil) }

    it "confirms an email address" do
      post confirm_admin_user_path(target)
      expect(target.reload.confirmed_at).to be_present
    end

    it "unlocks a locked account" do
      target.update!(locked_at: Time.current, confirmed_at: Time.current)

      post unlock_admin_user_path(target)

      expect(target.reload.locked_at).to be_nil
    end

    # `target` is referenced first on purpose: it is a lazy `let`, and creating a
    # user sends its own confirmation email, so building it inside the block
    # counts a delivery this example is not about.
    it "resends a confirmation email" do
      target
      expect { post resend_confirmation_admin_user_path(target) }
        .to change { ActionMailer::Base.deliveries.size }.by(1)
    end

    it "sends a password reset without setting a password" do
      target.update!(confirmed_at: Time.current)
      digest = target.encrypted_password

      expect { post send_password_reset_admin_user_path(target) }
        .to change { ActionMailer::Base.deliveries.size }.by(1)

      expect(target.reload.encrypted_password).to eq(digest)
    end

    it "grants instance admin" do
      post grant_admin_admin_user_path(target)
      expect(target.reload.admin).to be(true)
    end

    it "revokes instance admin" do
      other = create(:user, admin: true)

      delete revoke_admin_admin_user_path(other)

      expect(other.reload.admin).to be(false)
    end

    # Both refusals keep somebody able to get back in. `admin` is settable only
    # from this console and from a rake task on the server, so an instance with
    # zero administrators needs a shell to recover.
    it "refuses to let an administrator demote themselves" do
      delete revoke_admin_admin_user_path(admin)
      expect(admin.reload.admin).to be(true)
    end

    it "refuses to remove the last administrator" do
      expect(User.administrators.count).to eq(1)

      delete revoke_admin_admin_user_path(admin)

      expect(User.administrators.count).to eq(1)
    end
  end

  # The line this console must not cross. An operator can see that a site exists
  # and whether it is collecting; what it measured belongs to that customer's
  # audience, and /dpa says so without qualification.
  describe "customer measurement data" do
    before { sign_in admin }

    let!(:site) { create(:site, domain: "customer.example.com") }

    it "lists a site without offering a way into its dashboard" do
      create_event(site, path: "/a-private-path", visitor: "v1", at: 1.hour.ago)

      get "/admin/sites"

      expect(response.body).to include("customer.example.com")
      expect(response.body).not_to include("/a-private-path")
      expect(response.body).not_to include(site_path(site))
    end

    it "has no policy that would allow opening one" do
      context = AuthorizationContext.new(user: admin, account: nil)
      expect(Admin::SitePolicy.new(context, site).show?).to be(false)
    end

    it "shows a person's sites without linking to their data" do
      account = create(:account)
      create(:membership, account: account, user: regular, role: "owner")
      create(:site, account: account, domain: "theirs.example.com")

      get admin_user_path(regular)

      expect(response.body).to include("theirs.example.com")
      expect(response.body).not_to include(site_path(Site.find_by(domain: "theirs.example.com")))
    end

    # docs/privacy/claims.md is explicit that the account-holder sign-in IP exists
    # so a CUSTOMER can notice a sign-in that was not theirs. That is a reason for
    # them to see it, not a reason for an operator to browse it.
    it "does not display the stored sign-in IP" do
      regular.update!(current_sign_in_ip: "203.0.113.9", last_sign_in_ip: "203.0.113.9")

      get admin_user_path(regular)

      expect(response.body).not_to include("203.0.113.9")
    end
  end

  # /admin/users/4 would tell anyone who saw one URL roughly how many customers
  # exist, which is the reason every other routed model here uses a UUID.
  describe "public identifiers" do
    before { sign_in admin }

    it "routes users by public_id, not by id" do
      expect(admin_user_path(regular)).to include(regular.public_id)
      expect(admin_user_path(regular)).not_to include("/#{regular.id}")
    end

    it "follows its own generated URL" do
      get admin_user_path(regular)
      expect(response).to have_http_status(:ok)
    end

    it "404s on an unknown identifier" do
      get "/admin/users/#{SecureRandom.uuid}"
      expect(response).to have_http_status(:not_found)
    end
  end
end
