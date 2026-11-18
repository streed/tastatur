require "rails_helper"

# The credential screens have to be usable by a password manager, and every
# property that makes them so is invisible from Ruby — which is why they are
# pinned here rather than left to whoever edits the form next.
#
# A manager does two things, and Turbo Drive broke both:
#
#   FILLING needs a document load. A manager scans for fields when a document
#   loads; Turbo fetches the response and swaps the <body>, so arriving at the
#   sign-in form from anywhere inside the application produced no document and
#   no scan. Measured over CDP: clicking "Forgot your password?" and then "Sign
#   in" fired two `Page.navigatedWithinDocument` and zero `Page.frameNavigated`.
#   `turbo-visit-control: reload` is what hands those visits back to the browser.
#
#   SAVING needs a navigation after the submission. Turbo submits with `fetch`
#   and applies the redirect with pushState, so there is none. Measured before
#   the fix: POST /users/sign_in went out as `resourceType=Fetch` and
#   `Page.frameNavigated` never fired — sign-in worked perfectly and nothing was
#   ever offered to be saved. With `data-turbo="false"` the same POST is a
#   `Document` and the navigation fires.
#
# Neither is observable from a request spec, which issues its own HTTP and runs
# no JavaScript at all. What a request spec CAN do is assert the markup that
# decides it, which is what this file does — the same tactic as
# spec/requests/destructive_buttons_spec.rb and spec/requests/billing_spec.rb,
# both of which pin an attribute whose absence is silent everywhere else.
RSpec.describe "Password manager support", type: :request do
  let(:user) { create(:user, password: "correct horse battery staple") }

  # The <form> element for a given action, straight out of the delivered bytes.
  # Deliberately not parsed: what matters is the attribute as it is sent.
  def form_tag_for(action)
    response.body[/<form[^>]*action="#{Regexp.escape(action)}"[^>]*>/]
  end

  def field_tag(id)
    response.body[/<input[^>]*id="#{Regexp.escape(id)}"[^>]*>/]
  end

  # --- Filling ---------------------------------------------------------------

  describe "arriving at a credential screen" do
    # One assertion per screen rather than a loop, so a failure names the screen.
    {
      "the sign-in form" => "/users/sign_in",
      "the sign-up form" => "/users/sign_up",
      "the password reset request" => "/users/password/new"
    }.each do |description, path|
      it "loads #{description} as a real document, so a manager scans it" do
        get path

        expect(response.body).to include('<meta name="turbo-visit-control" content="reload">'),
                                 "#{path} can be reached by a Turbo visit, which swaps the body " \
                                 "without loading a document — a password manager never sees the " \
                                 "form and never offers to fill it."
      end
    end

    it "loads the two-factor challenge as a real document too" do
      user.update!(two_factor_enabled: true)
      post user_session_path, params: { user: { email: user.email, password: "correct horse battery staple" } }
      get two_factor_challenge_path

      expect(response.body).to include('<meta name="turbo-visit-control" content="reload">')
    end
  end

  # --- Saving ----------------------------------------------------------------

  describe "submitting a credential" do
    it "submits the sign-in form as a navigation, not a fetch" do
      get new_user_session_path

      expect(form_tag_for("/users/sign_in")).to include('data-turbo="false"'),
                                                "Turbo would submit this with fetch and apply the " \
                                                "redirect with pushState. No navigation, no " \
                                                "\"save password?\" prompt, and nothing to notice."
    end

    it "submits the sign-up form as a navigation" do
      get new_user_registration_path

      expect(form_tag_for("/users")).to include('data-turbo="false"')
    end

    it "submits the new-password form as a navigation" do
      token = user.send_reset_password_instructions
      get edit_user_password_path(reset_password_token: token)

      expect(form_tag_for("/users/password")).to include('data-turbo="false"')
    end

    it "submits the change-password form as a navigation" do
      sign_in user
      get edit_user_registration_path

      expect(form_tag_for("/users")).to include('data-turbo="false"')
    end

    it "finishes a two-factor sign-in as a navigation" do
      user.update!(two_factor_enabled: true)
      post user_session_path, params: { user: { email: user.email, password: "correct horse battery staple" } }
      get two_factor_challenge_path

      expect(form_tag_for("/two-factor")).to include('data-turbo="false"')
    end
  end

  # --- The attributes a manager reads the fields by --------------------------
  #
  # Correct before this change and asserted anyway: they are one word each, they
  # are what tells a manager which field is the account and which is the secret,
  # and a wrong one fails silently in exactly the same way everything else here
  # does.

  describe "the fields themselves" do
    it "names the account field and the secret on the sign-in form" do
      get new_user_session_path

      expect(field_tag("user_email")).to include('autocomplete="username"')
      expect(field_tag("user_password")).to include('autocomplete="current-password"')
    end

    it "asks for a NEW password on the sign-up form, so nothing offers the old one" do
      get new_user_registration_path

      expect(field_tag("user_password")).to include('autocomplete="new-password"')
      expect(field_tag("user_password_confirmation")).to include('autocomplete="new-password"')
    end

    it "asks for a new password on the reset form and the current one to authorise a change" do
      sign_in user
      get edit_user_registration_path

      expect(field_tag("user_password")).to include('autocomplete="new-password"')
      expect(field_tag("user_current_password")).to include('autocomplete="current-password"')
    end

    it "offers the emailed code to the platform's own autofill" do
      user.update!(two_factor_enabled: true)
      post user_session_path, params: { user: { email: user.email, password: "correct horse battery staple" } }
      get two_factor_challenge_path

      expect(field_tag("two_factor_challenge_code")).to include('autocomplete="one-time-code"')
    end
  end

  # --- What switching Turbo off must not have cost ---------------------------
  #
  # THE REGRESSION THIS CHANGE WAS ONE LINE AWAY FROM SHIPPING. Three of these
  # forms carried a `data-analytics-event` on the FORM, which the analytics
  # controller reports from `turbo:submit-end` and only when the server accepted
  # the submission. `turbo:submit-end` does not fire on a form that has opted
  # out, so all three would have gone quiet — no error, no failing spec, just a
  # funnel that stopped counting. They are recorded by the server now, through
  # the same mechanism as "Signed In".
  describe "the funnel steps that used to ride on turbo:submit-end" do
    # The event is handed to the NEXT page as a data attribute on <body>, so each
    # example has to arrive at a rendered page to see it. See SelfMeasurement.
    #
    # FOLLOWED IN A LOOP, not once: a successful sign-up redirects to "/", which
    # forwards again (§12), and the session survives both hops precisely because
    # SelfMeasurement uses the session rather than the flash — a flash would be
    # swept by the intermediate redirect and the event would never fire. One
    # `follow_redirect!` lands on the hop rather than the page.
    def follow_to_page!
      follow_redirect! while response.redirect?
    end

    it "still counts an accepted sign-up" do
      post user_registration_path,
           params: { user: { name: "Ada", email: "ada@example.com",
                             password: "correct horse battery staple",
                             password_confirmation: "correct horse battery staple" } }
      follow_to_page!

      expect(response.body).to include('data-analytics-load-event="Account Created"')
    end

    it "does not count a sign-up the server refused" do
      post user_registration_path,
           params: { user: { name: "Ada", email: "not-an-email", password: "x",
                             password_confirmation: "y" } }

      expect(response.body).not_to include("Account Created")
    end

    it "still counts a completed password reset" do
      token = user.send_reset_password_instructions

      put user_password_path,
          params: { user: { reset_password_token: token,
                            password: "a whole new passphrase",
                            password_confirmation: "a whole new passphrase" } }
      follow_to_page!

      expect(response.body).to include('data-analytics-load-event="Password Reset Completed"')
    end

    it "does not count a reset whose token had expired" do
      put user_password_path,
          params: { user: { reset_password_token: "not-a-real-token",
                            password: "a whole new passphrase",
                            password_confirmation: "a whole new passphrase" } }

      expect(response.body).not_to include("Password Reset Completed")
    end

    it "still counts a change of login details" do
      sign_in user

      put user_registration_path,
          params: { user: { name: "Ada Lovelace",
                            current_password: "correct horse battery staple" } }
      follow_to_page!

      expect(response.body).to include('data-analytics-load-event="Login Details Updated"')
    end

    it "does not count a change the server refused" do
      sign_in user

      put user_registration_path,
          params: { user: { email: "new@example.com", current_password: "wrong" } }

      expect(response.body).not_to include("Login Details Updated")
    end
  end
end
