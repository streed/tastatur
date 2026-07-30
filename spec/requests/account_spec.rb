require "rails_helper"

RSpec.describe "Account", type: :request do
  let(:user) { create(:user, name: "Original Name", password: "password") }
  let(:account) { create(:account, name: "Acme") }

  before do
    create(:membership, account: account, user: user, role: "owner")
    sign_in user
  end

  describe "GET /account" do
    it "renders account settings and the user's own login details together" do
      get "/account"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Acme")
      expect(response.body).to include("Your login")
      expect(response.body).to include("Change password")
      expect(response.body).to include(user.email)
    end

    it "offers a reset link for a user who does not know their current password" do
      get "/account"
      expect(response.body).to include("Email me a reset link")
    end
  end

  describe "updating login details" do
    it "changes the name without requiring the current password" do
      put "/users", params: { user: { name: "New Name", email: user.email } }

      expect(user.reload.name).to eq("New Name")
      expect(response).to redirect_to(account_path)
    end

    it "changes the password when the current one is supplied" do
      put "/users", params: { user: {
        email: user.email,
        password: "a-much-longer-password",
        password_confirmation: "a-much-longer-password",
        current_password: "password"
      } }

      expect(response).to redirect_to(account_path)
      expect(user.reload.valid_password?("a-much-longer-password")).to be(true)
    end

    # Devise enforces this; the spec exists so a future change to the form or the
    # sanitizer cannot quietly remove the requirement.
    it "refuses a password change without the current password" do
      put "/users", params: { user: {
        email: user.email,
        password: "a-much-longer-password",
        password_confirmation: "a-much-longer-password"
      } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.valid_password?("a-much-longer-password")).to be(false)
      expect(user.valid_password?("password")).to be(true)
    end

    it "refuses an email change without the current password" do
      put "/users", params: { user: { email: "attacker@example.test" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.unconfirmed_email).to be_nil
    end

    it "requires re-confirmation for a new email rather than switching immediately" do
      original = user.email

      put "/users", params: { user: { email: "new@example.test", current_password: "password" } }

      user.reload
      expect(user.email).to eq(original), "the signed-in address must not change until confirmed"
      expect(user.unconfirmed_email).to eq("new@example.test")
    end

    it "rejects a mismatched confirmation" do
      put "/users", params: { user: {
        email: user.email,
        password: "a-much-longer-password",
        password_confirmation: "something-else",
        current_password: "password"
      } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.valid_password?("password")).to be(true)
    end
  end
end
