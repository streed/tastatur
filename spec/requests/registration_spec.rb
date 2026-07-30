require "rails_helper"

RSpec.describe "Signing up", type: :request do
  before { ActionMailer::Base.deliveries.clear }

  let(:params) do
    { user: { name: "New Person", email: "new@example.test",
              password: "a-long-enough-password", password_confirmation: "a-long-enough-password" } }
  end

  describe "the happy path" do
    it "creates the user" do
      expect { post "/users", params: params }.to change(User, :count).by(1)
    end

    it "gives them an account to own, so there is somewhere to put a site" do
      post "/users", params: params

      user = User.find_by(email: "new@example.test")
      expect(user.accounts.count).to eq(1)
      expect(user.membership_for(user.default_account).role).to eq("owner")
    end

    it "names the account after them rather than 'Account 1'" do
      post "/users", params: params
      expect(User.find_by(email: "new@example.test").default_account.name).to eq("New's account")
    end

    it "sends a themed confirmation email from the configured address" do
      post "/users", params: params

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq(["new@example.test"])
      expect(mail.subject).to eq("Confirm your email address")
      expect(mail.body.to_s).to include("#c1440e"), "the accent is missing, so the layout was not applied"
      expect(mail.from.first).not_to include("please-change-me")
    end
  end

  describe "confirmation is required before use" do
    # allow_unconfirmed_access_for is set to 0.days explicitly. Left to Devise's
    # commented-out example (2.days), an unverified address would have a working
    # account for two days, which is long enough to sign up as an address you do
    # not control and use the service under it.
    it "refuses sign-in until the address is confirmed" do
      post "/users", params: params
      user = User.find_by(email: "new@example.test")
      expect(user.confirmed_at).to be_nil

      post "/users/sign_in", params: { user: { email: user.email, password: "a-long-enough-password" } }

      follow_redirect!
      expect(response.body).to match(/confirm/i)
      get "/sites"
      expect(response).to redirect_to(new_user_session_path)
    end

    it "allows sign-in once confirmed" do
      post "/users", params: params
      user = User.find_by(email: "new@example.test")
      user.confirm

      post "/users/sign_in", params: { user: { email: user.email, password: "a-long-enough-password" } }

      # A brand-new account has no sites, and the site list forwards straight to
      # "add a site" rather than showing an empty page. Reaching that at all is
      # what proves the session took.
      get "/sites"
      expect(response).to redirect_to(new_site_path)
    end
  end

  describe "when signup is closed" do
    before { allow(Tastatur).to receive(:allow_signup?).and_return(false) }

    it "refuses the form" do
      get "/users/sign_up"
      expect(response).to redirect_to(new_user_session_path)
    end

    it "refuses the POST, not just the form" do
      expect { post "/users", params: params }.not_to change(User, :count)
    end
  end
end

RSpec.describe "Inviting a teammate" do
  let(:owner) { create(:user) }
  let(:account) { create(:account) }

  before do
    create(:membership, account: account, user: owner, role: "owner")
    ActionMailer::Base.deliveries.clear
  end

  def invite(email = "colleague@example.test", role: "member")
    Accounts::InviteMember.call(account: account, email: email, role: role)
  end

  it "creates the user and the membership" do
    result = invite
    expect(result).to be_success
    expect(User.find_by(email: "colleague@example.test")).to be_present
    expect(account.reload.users.map(&:email)).to include("colleague@example.test")
  end

  # THE REGRESSION. The first implementation used
  # `skip_confirmation_notification!`, which suppresses the confirmation email
  # without confirming the user. The invitee could set a password through the
  # reset link and then still be refused at sign-in, with no confirmation email
  # ever sent — permanently locked out of an account they were invited to.
  it "leaves the invitee able to actually sign in" do
    invite
    invitee = User.find_by(email: "colleague@example.test")

    expect(invitee.confirmed_at).to be_present
    expect(invitee).to be_active_for_authentication
  end

  # The invitee is told how to get in, and the inviter never chooses their password.
  #
  # This used to assert Devise's bare "Reset your password" email. That is still the
  # underlying token, but sending it raw was the wrong envelope: out of context it
  # reads as "somebody tried to reset my password", and it never said who invited
  # them or to what. MemberInvitationMailer carries the same token with the context
  # attached, and it also covers the case Devise could not — an existing user added
  # to an account, who previously received nothing at all.
  it "emails the invitee a way in rather than letting the inviter choose a password" do
    expect { invite }.to have_enqueued_mail(MemberInvitationMailer, :invited)
  end

  it "gives the invitee a working reset token" do
    invite
    invitee = User.find_by(email: "colleague@example.test")

    expect(invitee.reset_password_token).to be_present
    expect(invitee.reset_password_sent_at).to be_present
  end

  it "gives the invitee a password nobody knows" do
    invite
    invitee = User.find_by(email: "colleague@example.test")

    expect(invitee.valid_password?("password")).to be(false)
    expect(invitee.encrypted_password).to be_present
  end

  it "adds an existing user without creating a second account for them" do
    existing = create(:user, email: "existing@example.test")

    expect { invite("existing@example.test") }.not_to change(User, :count)
    expect(account.reload.users).to include(existing)
  end

  it "refuses a duplicate membership" do
    invite
    expect(invite).to eq(Dry::Monads::Failure(:already_a_member))
  end

  it "refuses an unknown role rather than silently defaulting" do
    expect(invite(role: "superuser")).to eq(Dry::Monads::Failure(:invalid_role))
  end

  it "normalises the email so case cannot create a duplicate person" do
    invite("Colleague@Example.TEST")
    expect(User.where("lower(email) = ?", "colleague@example.test").count).to eq(1)
  end
end
