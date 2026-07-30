require "rails_helper"

# Signing in with a second factor, end to end through the forms.
#
# Devise's test helper is deliberately not used for the sign-in itself: it sets
# the Warden session directly, which is exactly the step this feature interposes
# on. A spec that used it would assert nothing about the thing being built.
RSpec.describe "Two-factor authentication", type: :request do
  let(:user) { create(:user, :with_account, :with_two_factor, password: "a-long-enough-password") }

  # The code exists only in the email, which is also true of the application.
  #
  # The form is fetched first because that is what a browser does, and because
  # the very first request a process serves does not authenticate — leave it out
  # and these examples fail when run alone while passing in a full suite. Same
  # note as spec/requests/auth_funnel_spec.rb.
  def sign_in_with_password(as: user, password: "a-long-enough-password", remember_me: nil)
    params = { user: { email: as.email, password: password } }
    params[:user][:remember_me] = remember_me unless remember_me.nil?

    get "/users/sign_in"
    perform_enqueued_jobs { post "/users/sign_in", params: params }
  end

  def last_code
    ActionMailer::Base.deliveries.last&.subject&.[](/\d{6}/)
  end

  def submit_code(code, trust_device: false)
    post "/two-factor", params: { two_factor_challenge: { code: code, trust_device: trust_device ? "1" : "0" } }
  end

  before { ActionMailer::Base.deliveries.clear }

  describe "a user who has not switched it on" do
    let(:plain) { create(:user, :with_account, password: "a-long-enough-password") }

    it "signs in in one step, exactly as before" do
      sign_in_with_password(as: plain)

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response).not_to redirect_to(two_factor_challenge_path)
    end

    it "is sent no code" do
      expect { sign_in_with_password(as: plain) }.not_to change { ActionMailer::Base.deliveries.size }
    end

    # Devise's trackable is suppressed on the sign-in request and re-run
    # explicitly, so this asserts the one-step path did not lose it on the way.
    it "still records the sign-in against the account" do
      expect { sign_in_with_password(as: plain) }.to change { plain.reload.sign_in_count }.from(0).to(1)
      expect(plain.reload.current_sign_in_at).to be_present
    end
  end

  describe "the challenge" do
    it "holds the sign-in and emails a code" do
      sign_in_with_password

      expect(response).to redirect_to(two_factor_challenge_path)
      expect(last_code).to match(/\A\d{6}\z/)
    end

    # THE PROPERTY THE WHOLE DESIGN RESTS ON. A password alone must leave no
    # authenticated session anywhere — not a gated one, not a half one. Sidekiq's
    # console authenticates through Warden inside the routes file, where no
    # controller callback can reach it, so "signed in but blocked by a
    # before_action" would have been a real hole.
    it "leaves no session at all until the code is entered" do
      sign_in_with_password

      get "/sites"
      expect(response).to redirect_to(new_user_session_path)
    end

    it "does not count as a sign-in until the code is entered" do
      expect { sign_in_with_password }.not_to change { user.reload.sign_in_count }
      expect(user.reload.current_sign_in_at).to be_nil
    end

    it "signs in when the right code is given" do
      sign_in_with_password
      submit_code(last_code)

      expect(response).to redirect_to(root_path)

      get "/sites"
      expect(response).not_to redirect_to(new_user_session_path)
    end

    it "counts the sign-in once the code lands" do
      sign_in_with_password
      expect { submit_code(last_code) }.to change { user.reload.sign_in_count }.from(0).to(1)
    end

    it "accepts a code that was pasted with spaces around it" do
      sign_in_with_password
      code = last_code

      submit_code(" #{code[0, 3]} #{code[3, 3]} ")

      expect(response).to redirect_to(root_path)
    end

    it "refuses a wrong code and stays on the challenge" do
      sign_in_with_password
      submit_code("000000")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("is not correct")
    end

    it "sends a fresh code and starts over once the attempts are spent" do
      sign_in_with_password
      first = last_code

      TwoFactor::IssueChallenge::MAX_ATTEMPTS.times { submit_code("000000") }

      expect(response).to redirect_to(two_factor_challenge_path)
      follow_redirect!
      expect(response.body).to include("Too many incorrect codes")

      # The original code is dead even though the sign-in is still pending.
      submit_code(first)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses a malformed submission without spending an attempt" do
      sign_in_with_password
      submit_code("not-a-code")

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.two_factor_failed_attempts).to eq(0)
    end

    # `code[]=1` reaches BCrypt::Password#== as an Array, which raises rather
    # than returning false. That is a 500 on the sign-in path from a request
    # anyone can type into a URL bar. It is also why this endpoint reads its
    # params with `permit` instead of `expect` — see the controller.
    it "answers a non-string code with the form, not an error page" do
      sign_in_with_password

      post "/two-factor", params: { two_factor_challenge: { code: %w[1 2] } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Enter your code"), "the challenge form should come back"
      expect(user.reload.two_factor_failed_attempts).to eq(0)
    end

    it "answers a submission with no parameters at all the same way" do
      sign_in_with_password

      post "/two-factor"

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.two_factor_failed_attempts).to eq(0)
    end

    it "times the pending sign-in out rather than leaving it open" do
      sign_in_with_password

      travel_to(TwoFactor::PendingSignIn::TTL.from_now + 1.second) do
        get "/two-factor"
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    # Devise carries the authenticatable salt in a real session for exactly this
    # reason; a half-finished sign-in needs the same protection. Resetting the
    # password *because* it was stolen must not leave the thief able to finish.
    it "is invalidated by a password change made in between" do
      sign_in_with_password
      code = last_code

      user.update!(password: "a-completely-different-one")

      submit_code(code)
      expect(response).to redirect_to(new_user_session_path)
    end

    it "can be abandoned" do
      sign_in_with_password

      delete "/two-factor"

      expect(response).to redirect_to(new_user_session_path)
      get "/two-factor"
      expect(response).to redirect_to(new_user_session_path)
    end

    it "cannot be reached without a password having been accepted" do
      get "/two-factor"
      expect(response).to redirect_to(new_user_session_path)

      submit_code("123456")
      expect(response).to redirect_to(new_user_session_path)
    end

    it "reports nothing for a wrong password" do
      sign_in_with_password(password: "not-it")

      expect(response).to have_http_status(:unprocessable_content)
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end

  describe "resending" do
    it "issues a new code and kills the old one" do
      sign_in_with_password
      first = last_code

      travel_to(TwoFactor::IssueChallenge::RESEND_INTERVAL.from_now + 1.second) do
        perform_enqueued_jobs { post "/two-factor/resend" }
        second = last_code

        expect(second).not_to eq(first)

        submit_code(first)
        expect(response).to have_http_status(:unprocessable_content)

        submit_code(second)
        expect(response).to redirect_to(root_path)
      end
    end

    it "declines politely inside the resend interval rather than sending again" do
      sign_in_with_password

      expect { perform_enqueued_jobs { post "/two-factor/resend" } }
        .not_to change { ActionMailer::Base.deliveries.size }

      follow_redirect!
      expect(response.body).to include("A code was just sent")
    end
  end

  describe "trusted devices" do
    def sign_in_and_trust
      sign_in_with_password
      submit_code(last_code, trust_device: true)
      delete "/users/sign_out"
    end

    it "skips the challenge next time" do
      sign_in_and_trust

      expect { sign_in_with_password }.not_to change { ActionMailer::Base.deliveries.size }
      expect(response).to redirect_to(root_path)
    end

    it "does not skip it when the box was left unticked" do
      sign_in_with_password
      submit_code(last_code, trust_device: false)
      delete "/users/sign_out"

      sign_in_with_password
      expect(response).to redirect_to(two_factor_challenge_path)
    end

    it "records the row and stamps it as used" do
      sign_in_and_trust

      device = user.trusted_devices.sole
      expect(device.expires_at).to be_within(1.minute).of(TrustedDevice::TRUST_DURATION.from_now)

      sign_in_with_password
      expect(device.reload.last_used_at).to be_within(1.minute).of(Time.current)
    end

    it "challenges again once the trust has expired" do
      sign_in_and_trust

      travel_to(TrustedDevice::TRUST_DURATION.from_now + 1.day) do
        sign_in_with_password
        expect(response).to redirect_to(two_factor_challenge_path)
      end
    end

    # A cookie is not a bearer of somebody else's trust. Without the ownership
    # check, one account's device cookie would silently satisfy another
    # account's challenge on a shared browser.
    it "does not let one person's device skip another person's challenge" do
      sign_in_and_trust
      other = create(:user, :with_account, :with_two_factor, password: "a-long-enough-password")

      sign_in_with_password(as: other)

      expect(response).to redirect_to(two_factor_challenge_path)
    end

    it "challenges again after the device is forgotten" do
      sign_in_and_trust
      sign_in_with_password
      device = user.trusted_devices.sole

      delete trusted_device_path(device)
      delete "/users/sign_out"

      sign_in_with_password
      expect(response).to redirect_to(two_factor_challenge_path)
    end

    it "challenges again after every device is forgotten" do
      sign_in_and_trust
      sign_in_with_password

      delete all_trusted_devices_path
      delete "/users/sign_out"

      sign_in_with_password
      expect(response).to redirect_to(two_factor_challenge_path)
    end

    it "refuses to forget somebody else's device" do
      someone_elses = create(:trusted_device)
      sign_in_and_trust
      sign_in_with_password

      delete trusted_device_path(someone_elses)

      expect(response).to have_http_status(:not_found)
      expect(TrustedDevice.exists?(someone_elses.id)).to be(true)
    end
  end

  describe "remember me" do
    it "is not applied while the sign-in is only half done" do
      sign_in_with_password(remember_me: "1")

      expect(response.cookies["remember_user_token"]).to be_blank
      expect(user.reload.remember_created_at).to be_nil
    end

    it "is applied once the code lands" do
      sign_in_with_password(remember_me: "1")
      submit_code(last_code)

      expect(response.cookies["remember_user_token"]).to be_present
    end

    it "is not applied when it was not asked for" do
      sign_in_with_password(remember_me: "0")
      submit_code(last_code)

      expect(response.cookies["remember_user_token"]).to be_blank
    end
  end

  describe "the settings screen" do
    it "turns it on and off for yourself" do
      plain = create(:user, :with_account)
      sign_in plain

      post two_factor_setting_path
      expect(plain.reload.two_factor_enabled?).to be(true)

      delete two_factor_setting_path
      expect(plain.reload.two_factor_enabled?).to be(false)
    end

    it "forgets trusted devices when switched off" do
      sign_in user
      create_list(:trusted_device, 2, user: user)

      delete two_factor_setting_path

      expect(user.trusted_devices.reload).to be_empty
    end

    # TwoFactor::Enable's `:unconfirmed` branch is not reachable from here, and
    # that is worth asserting rather than assuming: :confirmable refuses to keep
    # an unconfirmed user signed in at all, so the settings screen is closed to
    # them one layer earlier. The service-level guard stays as the thing that
    # keeps "no enrolment challenge needed" true if that ever changes — see
    # spec/services/two_factor/enable_spec.rb.
    it "is closed to an unconfirmed address before the service is even reached" do
      unconfirmed = create(:user, :unconfirmed, :with_account)
      sign_in unconfirmed

      post two_factor_setting_path

      expect(response).to redirect_to(new_user_session_path)
      expect(unconfirmed.reload.two_factor_enabled?).to be(false)
    end

    it "is shown on the account page" do
      sign_in user
      get account_path

      expect(response.body).to include("Two-factor authentication")
    end
  end

  describe "the funnel step the server has to report" do
    def load_event
      response.body[/data-analytics-load-event="([^"]*)"/, 1]
    end

    def load_props
      raw = response.body[/data-analytics-load-props="([^"]*)"/, 1]
      raw && JSON.parse(CGI.unescapeHTML(raw))
    end

    def follow_redirects
      5.times { response.redirect? ? follow_redirect! : break }
    end

    # "Signed In" is recorded by a Warden hook the moment a password is accepted,
    # and the session that carries it is thrown away when a challenge is raised.
    # Without the challenge controller writing it again, every two-factor user
    # would silently drop out of the funnel at the last step.
    it "reports the sign-in on the page reached after the code, not before it" do
      sign_in_with_password
      follow_redirects
      expect(load_event).to be_nil, "a password alone is not a sign-in"

      submit_code(last_code)
      follow_redirects

      expect(load_event).to eq("Signed In")
    end

    # `sign_in_count` is read before Devise's trackable hook increments it. With
    # the two-step flow the read and the increment happen in different requests,
    # which is exactly where an ordering assumption goes quietly wrong.
    it "can still tell a first sign-in from a return" do
      sign_in_with_password
      submit_code(last_code)
      follow_redirects
      expect(load_props).to eq("first_sign_in" => true)

      delete "/users/sign_out"

      travel_to(TwoFactor::IssueChallenge::RESEND_INTERVAL.from_now + 1.second) do
        sign_in_with_password
        submit_code(last_code)
        follow_redirects

        expect(load_props).to eq("first_sign_in" => false)
      end
    end
  end
end
