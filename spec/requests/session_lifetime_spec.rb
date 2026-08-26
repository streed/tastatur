require "rails_helper"

# How long being signed in lasts, and what happens at the moment it stops.
#
# Before :timeoutable was enabled a session lasted until somebody deleted the
# cookie — no idle bound, no absolute lifetime, forever. That is a defensible
# trade for a product holding visitor counts and a poor one for a product
# holding a customer list and revenue figures (§18).
RSpec.describe "Session lifetime", type: :request do
  let(:password) { "flint-marrow-cadence" }
  let(:user) { create(:user, password: password) }
  let(:account) { create(:account) }

  before { create(:membership, account: account, user: user, role: "owner") }

  # The form rather than Devise's test helper, because what is under test is the
  # session the sign-in produces rather than one conjured around it.
  #
  # The screen is fetched first for the reason spec/requests/auth_funnel_spec.rb
  # records: the very first request a process serves does not authenticate, so
  # leaving the GET out makes an example pass in a full run and fail on its own.
  def sign_in_through_the_form(remember: false)
    get "/users/sign_in"
    post "/users/sign_in",
         params: { user: { email: user.email, password: password, remember_me: remember ? "1" : "0" } }
  end

  it "keeps somebody signed in inside the window" do
    sign_in_through_the_form

    travel_to(Devise.timeout_in.from_now - 1.minute) do
      get "/account"
      expect(response).to have_http_status(:ok)
    end
  end

  # TWO HOPS, AND THE FIRST ONE LOOKS WRONG UNTIL YOU KNOW WHY. Devise's failure
  # app answers a timed-out GET with a redirect to the path that was attempted,
  # not to the sign-in form — so that whoever signs in again lands where they
  # were rather than on a dashboard. That second request is the unauthenticated
  # one, and it is the one that reaches the form.
  it "asks for the password again after the idle window" do
    sign_in_through_the_form

    travel_to(Devise.timeout_in.from_now + 1.minute) do
      get "/account"
      expect(response).to redirect_to(account_url)

      follow_redirect!
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  # It is an IDLE timeout, not an absolute one — activity should keep somebody
  # working rather than throwing them out mid-task.
  it "extends the window on each request" do
    sign_in_through_the_form

    travel_to(Devise.timeout_in.from_now - 1.minute) { get "/account" }

    travel_to(Devise.timeout_in.from_now + 1.minute) do
      get "/account"
      expect(response).to have_http_status(:ok)
    end
  end

  # The half that makes the timeout mean anything. Devise re-authenticates a
  # timed-out session from the remember-me cookie without showing anybody a
  # form, so an uncapped `remember_for` would be a timeout that never fires.
  describe "remember me" do
    it "is capped rather than left at whatever Devise defaults to" do
      expect(Devise.remember_for).to be <= 2.weeks
    end

    it "outlives the idle timeout, which is why the cap above exists" do
      sign_in_through_the_form(remember: true)

      travel_to(Devise.timeout_in.from_now + 1.minute) do
        get "/account"
        expect(response).to have_http_status(:ok)
      end
    end

    it "does not outlive its own window" do
      sign_in_through_the_form(remember: true)

      travel_to(Devise.remember_for.from_now + 1.day) do
        get "/account"
        follow_redirect! while response.redirect? && response.location != new_user_session_url

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # Session fixation. TwoFactor::ChallengesController always reset before
  # signing in; this path — every user WITHOUT a second factor — did not.
  describe "the session the sign-in produces" do
    it "signs the person in, which is the thing `force: true` protects" do
      sign_in_through_the_form

      get "/account"
      expect(response).to have_http_status(:ok)
    end

    # The reset discards everything in the session, including the page somebody
    # was trying to reach. It is read out first and put back.
    it "still returns to the page that sent them to the sign-in form" do
      get "/account"
      expect(response).to redirect_to(new_user_session_path)

      sign_in_through_the_form
      expect(response).to redirect_to(account_url)
    end
  end
end
