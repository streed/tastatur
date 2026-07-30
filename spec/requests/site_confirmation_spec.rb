require "rails_helper"

# A site may not be created against an unconfirmed email address.
#
# WHY THIS SPEC LOOKS OVER-ENGINEERED FOR A ONE-LINE POLICY CHANGE. Through the
# sign-in form the rule is currently unreachable: `allow_unconfirmed_access_for`
# is `0.days`, so :confirmable refuses to keep an unconfirmed user signed in at
# all. That makes the guarantee rest on a single number in an initializer, and
# relaxing that number is an ordinary thing to want — "let people look around
# before they confirm" is a normal product decision that nobody would expect to
# hand out site creation as a side effect.
#
# So these examples come at it from both ends: the policy, which is where the
# rule actually lives and can be tested directly, and the request layer, which
# proves the current arrangement holds and that the refusal explains itself.
RSpec.describe "Creating a site needs a confirmed address", type: :request do
  let(:account) { create(:account) }

  def context_for(user, role: "owner")
    create(:membership, account: account, user: user, role: role)
    AuthorizationContext.new(user: user.reload, account: account)
  end

  describe "SitePolicy" do
    it "allows an admin whose address is confirmed" do
      policy = SitePolicy.new(context_for(create(:user), role: "admin"), Site.new(account: account))

      expect(policy.create?).to be(true)
    end

    it "refuses an owner whose address is not confirmed" do
      policy = SitePolicy.new(context_for(create(:user, :unconfirmed)), Site.new(account: account))

      expect(policy.create?).to be(false)
    end

    # Confirmation is a precondition for taking on an obligation, not for looking
    # at what you already have — and least of all for getting out.
    it "still allows reading and deleting" do
      user = create(:user, :unconfirmed)
      site = create(:site, account: account)
      policy = SitePolicy.new(context_for(user), site)

      expect(policy.show?).to be(true)
      expect(policy.stats?).to be(true)
      expect(policy.destroy?).to be(true)
    end

    # `reconfirmable` keeps `confirmed_at` set while a NEW address is pending, so
    # changing your email must not take site creation away in the meantime.
    it "is unaffected by a pending email change" do
      user = create(:user)
      user.update!(email: "somewhere-else@example.test")
      expect(user.reload.pending_reconfirmation?).to be(true)

      policy = SitePolicy.new(context_for(user), Site.new(account: account))

      expect(policy.create?).to be(true)
    end
  end

  describe "through the application" do
    let(:confirmed) { create(:user, :with_account) }

    it "lets a confirmed owner add one" do
      sign_in confirmed
      get new_site_path

      expect(response).to have_http_status(:ok)
    end

    # The layer that makes the policy unreachable today. Asserted rather than
    # assumed, because if it ever stops being true the examples below start
    # carrying the whole weight.
    it "will not keep an unconfirmed user signed in at all" do
      sign_in create(:user, :unconfirmed, :with_account)

      get new_site_path

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  # With the Devise gate lifted — which is the state this rule exists for — the
  # refusal has to be the application's own, and it has to say something useful.
  describe "if unconfirmed users were ever allowed to hold a session" do
    let(:user) { create(:user, :unconfirmed, :with_account) }

    around do |example|
      original = User.allow_unconfirmed_access_for
      User.allow_unconfirmed_access_for = 1.week
      example.run
      User.allow_unconfirmed_access_for = original
    end

    before { sign_in user }

    it "refuses the form and names the actual reason" do
      get new_site_path

      expect(response).to redirect_to(sites_path)
      follow_redirect!
      expect(response.body).to include("Confirm your email address before adding a site")
    end

    it "refuses the submission, not just the form" do
      expect {
        post sites_path, params: { site: { domain: "example.com", timezone: "Etc/UTC", k_anonymity_threshold: 25 } }
      }.not_to change { Site.count }

      expect(response).to redirect_to(sites_path)
    end

    # The loop this closes: the site list redirects an empty account to the form,
    # the form redirects back to the list, and `deny_access` redirects back again
    # using the referer. Reachable by an ordinary person, and it renders the
    # application unusable rather than merely refusing them.
    it "shows the empty site list instead of bouncing to a form that refuses" do
      get sites_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Confirm your email address to add a site")
    end

    it "offers a way to get the confirmation email again" do
      get sites_path

      expect(response.body).to include(new_user_confirmation_path)
    end

    it "does not offer an Add a site button it would refuse" do
      get sites_path

      expect(response.body).not_to include(">Add a site<")
    end
  end

  # The same loop, for the person it was already reachable by before any of this.
  describe "a viewer with nothing to look at" do
    it "sees an empty list rather than a redirect loop" do
      viewer = create(:user)
      create(:membership, account: account, user: viewer, role: "viewer")
      sign_in viewer

      get sites_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No sites here yet")
    end
  end
end
