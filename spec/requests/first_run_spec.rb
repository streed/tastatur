require "rails_helper"

# A fresh self-hosted install has no users, and the app sends the operator to a
# setup wizard. Which pages that redirect applies to is a deployment concern, not
# a cosmetic one.
RSpec.describe "First-run setup", type: :request do
  before do
    allow(Tastatur).to receive(:self_hosted?).and_return(true)
    User.delete_all
  end

  it "is what a fresh install needs" do
    expect(Tastatur.needs_first_run_setup?).to be(true)
  end

  # THE REGRESSION, and it only ever appears on the very first deploy.
  #
  # The redirect originally applied to everything, so /up returned 302 on a fresh
  # install. A platform health check never saw a 200, the deploy never went
  # healthy, and setup could therefore never be completed — the service was never
  # brought up to run it. Railway's healthcheckPath is /up, so this would have
  # failed the first deploy with a message about the health check rather than
  # anything pointing at the cause.
  describe "the health check" do
    it "answers 200 before setup, not a redirect" do
      get "/up"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["status"]).to eq("ok")
    end

    it "still reports failure honestly rather than being blanket-exempted" do
      allow(REDIS_POOL).to receive(:with).and_raise(Redis::CannotConnectError)

      get "/up"

      expect(response).to have_http_status(:service_unavailable)
      expect(JSON.parse(response.body).dig("checks", "redis")).not_to eq("ok")
    end
  end

  # Nothing about an unconfigured instance makes its privacy policy private.
  describe "public informational pages" do
    # /about and /faq are the same rule, asserted in the edition that owns them.
    %w[/privacy /privacy-policy /terms /dpa /docs].each do |path|
      it "serves #{path} before setup" do
        get path
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "pages that should send you to setup" do
    # /users/sign_in among them: an install with no users yet has nobody to sign
    # in as, and without a marketing edition it is where `/` forwards to.
    %w[/ /sites /account /users/sign_in].each do |path|
      it "redirects #{path}" do
        get path
        expect(response).to redirect_to(first_run_path)
      end
    end
  end

  describe "the wizard itself" do
    it "renders" do
      get "/setup"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Welcome to your Tastatur instance")
    end

    it "creates the owner, their account and their first site" do
      post "/setup", params: {
        user: { email: "operator@example.test", password: "a-long-enough-password" },
        site: { domain: "myproject.example.com", timezone: "Etc/UTC", k_anonymity_threshold: 25 }
      }

      user = User.find_by(email: "operator@example.test")
      expect(user).to be_present
      expect(user.confirmed_at).to be_present, "must be usable without configured mail"
      expect(user.accounts.count).to eq(1)
      expect(user.sites.map(&:domain)).to eq(["myproject.example.com"])
    end

    it "signs the operator in rather than making them find the login form" do
      post "/setup", params: {
        user: { email: "operator@example.test", password: "a-long-enough-password" },
        site: { domain: "myproject.example.com", timezone: "Etc/UTC", k_anonymity_threshold: 25 }
      }

      expect(response).to redirect_to(sites_path)
      follow_redirect!
      expect(response).to have_http_status(:ok).or redirect_to(new_site_path)
    end

    # It must not become a way to mint an owner account on a running instance.
    it "closes itself once a user exists" do
      create(:user)

      get "/setup"
      expect(response).to redirect_to(root_path)

      expect {
        post "/setup", params: {
          user: { email: "sneaky@example.test", password: "a-long-enough-password" },
          site: { domain: "sneaky.example.com" }
        }
      }.not_to change(User, :count)
    end

    # The whole thing is one transaction, so a bad site must not leave a user and
    # an account behind for a wizard that has already closed itself.
    it "re-renders with errors rather than half-creating on invalid input" do
      counts = -> { [User.count, Site.count, Account.count] }
      before = counts.call

      post "/setup", params: {
        user: { email: "not-an-email", password: "short" },
        site: { domain: "" }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(counts.call).to eq(before)
    end
  end

  context "when not self-hosted" do
    before { allow(Tastatur).to receive(:self_hosted?).and_return(false) }

    # Asserted on the sign-in form rather than on `/`, which is a landing page on
    # a deployment carrying a marketing edition and a redirect to this form on
    # one that is not. This page is the same on both and is subject to the same
    # redirect, so it is what proves the wizard has stood down.
    it "does not force setup, because the hosted service uses normal signup" do
      expect(Tastatur.needs_first_run_setup?).to be(false)

      get "/users/sign_in"
      expect(response).to have_http_status(:ok)
    end

    it "makes the wizard unreachable" do
      get "/setup"
      expect(response).to redirect_to(root_path)
    end
  end
end
