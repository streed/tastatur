require "rails_helper"

# The one funnel this instance measures on itself that crosses the boundary
# between the browser and the server: landing, sign-up screen, sign-up submitted,
# account created, signed in.
#
# The first two steps are pageviews and need nothing here. The rest are events,
# and the last of them cannot be observed by the page at all — a sign-in that
# worked and one that did not are the same submitted form, and the page that
# renders afterwards is a redirect target that knows nothing about how anyone
# arrived at it. So the server records it and the next page carries it, which is
# a wire with two ends and no type checking between them; these examples are what
# holds the two ends together.
RSpec.describe "Auth funnel instrumentation", type: :request do
  def annotations
    response.body.scan(/data-analytics-[a-z-]+="([^"]*)"/).flatten
  end

  def load_event
    response.body[/data-analytics-load-event="([^"]*)"/, 1]
  end

  def load_props
    raw = response.body[/data-analytics-load-props="([^"]*)"/, 1]
    raw && JSON.parse(CGI.unescapeHTML(raw))
  end

  # The form, not Devise's test helper: what is being measured here is the
  # authentication itself, and the helper skips it. The screen is fetched first
  # because that is what a browser does, and because the very first request a
  # process serves does not authenticate — leave it out and an example run on its
  # own fails while the same example passes in a full run.
  def sign_in_through_the_form(user, password: "password")
    get "/users/sign_in"
    post "/users/sign_in", params: { user: { email: user.email, password: password } }
    follow_redirects
  end

  # Signing in lands on "/", which redirects a signed-in visitor onwards, so the
  # page that finally renders — and therefore carries the event — is a couple of
  # hops away. Bounded rather than `while response.redirect?`, because a redirect
  # cycle should fail this suite instead of hanging it.
  def follow_redirects
    5.times { response.redirect? ? follow_redirect! : break }
  end

  describe "the screens" do
    it "counts an attempted sign-up and an accepted one separately" do
      get "/users/sign_up"

      expect(annotations).to include("Sign Up Submitted", "Account Created")
    end

    it "counts the sign-in attempt on the button, since the server judges the rest" do
      get "/users/sign_in"

      expect(annotations).to include("Sign In Submitted")
    end

    it "counts a request on each recovery screen" do
      {
        "/users/password/new" => "Password Reset Requested",
        "/users/confirmation/new" => "Confirmation Requested",
        "/users/unlock/new" => "Unlock Requested"
      }.each do |path, event|
        get path
        expect(annotations).to include(event), "#{path} is not instrumented"
      end
    end

    it "counts the far end of a password reset, where the link actually worked" do
      user = create(:user)
      token = user.send_reset_password_instructions

      get "/users/password/edit?reset_password_token=#{token}"

      expect(annotations).to include("Password Reset Completed")
    end

    it "counts a completed first-run setup" do
      allow(Tastatur).to receive(:self_hosted?).and_return(true)
      User.delete_all

      get "/setup"

      expect(annotations).to include("First Run Completed")
    end
  end

  describe "signing in, which only the server can report" do
    # :with_account because a signed-in user who belongs to no account is bounced
    # back and forth between the site list and the root path, which is a separate
    # problem and not this one.
    let(:user) { create(:user, :with_account) }

    it "records it on the page the visitor lands on" do
      sign_in_through_the_form(user)

      expect(load_event).to eq("Signed In")
    end

    # THE ORDERING THIS PINS. `sign_in_count` is read in a Warden callback, and
    # Devise's trackable hook — which increments it — is registered when the User
    # model loads, after every initializer. Warden runs callbacks in registration
    # order, so ours sees the value from before this sign-in and zero means "never
    # signed in before". Should that order ever change, every returning customer
    # would be reported as a new one, silently and forever. This fails instead.
    it "can tell a first sign-in from a return without keeping who signed in" do
      sign_in_through_the_form(user)
      expect(load_props).to eq("first_sign_in" => true)

      delete "/users/sign_out"
      sign_in_through_the_form(user)

      expect(load_props).to eq("first_sign_in" => false)
    end

    it "reports nothing when the password was wrong" do
      sign_in_through_the_form(user, password: "not-it")

      expect(response).to have_http_status(:unprocessable_content)
      expect(load_event).to be_nil
    end

    it "reports nothing for an account that has not confirmed its address yet" do
      unconfirmed = create(:user, :unconfirmed)

      sign_in_through_the_form(unconfirmed)

      expect(load_event).to be_nil
    end

    # Turbo caches the body it is written on, and a visitor returning to that page
    # from the snapshot cache would report the sign-in a second time. The
    # annotation is therefore removed as it is read, at both ends: here, and in
    # the Stimulus controller's connect().
    it "fires once, not on every page afterwards" do
      sign_in_through_the_form(user)
      expect(load_event).to eq("Signed In")

      get "/sites"
      follow_redirects

      expect(load_event).to be_nil
    end

    it "is read by the controller that is supposed to read it" do
      # The layout writes an attribute nothing else in the application looks at.
      # If the analytics controller is rewritten without it, the last step of the
      # funnel stops arriving and every other spec here still passes, because
      # nothing in a request spec runs the JavaScript.
      source = Rails.root.join("app/javascript/controllers/analytics_controller.js").read

      expect(source).to include("analyticsLoadEvent"),
                        "the layout still writes data-analytics-load-event, so something must still read it"
    end
  end

  # The claim on /privacy is about visitors to customer sites, but it would be a
  # strange thing to break on ourselves. An email address is the one identifier
  # every screen in this funnel is handling, so it is the one to check for.
  describe "what is never sent" do
    it "puts nothing from the form into an annotation, even when it comes back rejected" do
      create(:user, email: "taken@example.test")

      post "/users", params: { user: { name: "Someone", email: "taken@example.test",
                                       password: "a-long-enough-password",
                                       password_confirmation: "a-long-enough-password" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(annotations).to all(satisfy { |value| !value.include?("taken@example.test") })
    end

    it "identifies a signed-in person by nothing at all" do
      user = create(:user, :with_account, email: "someone@example.test",
                                          account_name: "Distinctive Account")

      sign_in_through_the_form(user)

      # The whole annotation, not just the recorded event: the page that carries
      # it is a signed-in one, so a helper that started interpolating the current
      # account into an event would show up here too.
      identifying = [user.email, user.id.to_s, user.default_account.name, user.default_account.slug]

      expect(annotations).to all(satisfy { |value| identifying.none? { |secret| value.include?(secret) } })
    end
  end
end
