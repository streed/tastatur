require "rails_helper"

# The waitlist for revenue attribution, driven over HTTP because the properties
# that matter are properties of the delivered pages: that three surfaces carry
# the form, that a mail client prefetching a link cannot delete anybody, and
# that no response tells a stranger whether a given address is on the list.
RSpec.describe "The waitlist", type: :request do
  def join(email:, source: "revenue_page", **extra)
    perform_enqueued_jobs do
      post "/waitlist", params: { waitlist_signup: { email: email, source: source, **extra } }
    end
  end

  def emailed_token
    ActionMailer::Base.deliveries.last.body.to_s[%r{waitlist/confirm/([\w\-]+)}, 1]
  end

  before { ActionMailer::Base.deliveries.clear }

  describe "where the form appears" do
    it "is on the revenue page" do
      get "/revenue"

      expect(response.body).to include('action="/waitlist"')
      expect(response.body).to include('value="revenue_page"')
    end

    it "is on the pricing page" do
      get "/pricing"

      expect(response.body).to include('action="/waitlist"')
      expect(response.body).to include('value="pricing_page"')
    end

    # In-app, where the Revenue card used to explain an environment variable to
    # somebody who cannot set one.
    #
    # The suite configures Stripe Connect globally (see spec/support/stripe.rb),
    # which is the state where the feature IS available — so these three
    # examples say which of the card's three branches each instance gets.
    describe "in site settings" do
      let(:user) { create(:user) }
      let(:account) { create(:account) }
      let(:site) { create(:site, account: account) }

      before do
        create(:membership, account: account, user: user, role: "owner")
        sign_in user
      end

      it "offers the list on the hosted service, where nobody reading can set an env var" do
        allow(Tastatur).to receive_messages(revenue_enabled?: false, self_hosted?: false)

        get "/sites/#{site.to_param}/edit"

        expect(response.body).to include('value="site_settings"')
        # Prefilled: we are talking to somebody signed in, and asking them to
        # type an address we already have would be theatre.
        expect(response.body).to include(user.email)
      end

      # A self-hosted operator CAN fix it, so they keep the message saying how.
      it "keeps the operator's instructions on a self-hosted instance" do
        allow(Tastatur).to receive_messages(revenue_enabled?: false, self_hosted?: true)

        get "/sites/#{site.to_param}/edit"

        expect(response.body).to include("STRIPE_CONNECT_CLIENT_ID")
        expect(response.body).not_to include('value="site_settings"')
      end

      # PRESENTATION ONLY: the working feature was not touched. An instance with
      # Connect configured still gets the connect flow and no waitlist form.
      it "still offers the real thing where it is configured" do
        get "/sites/#{site.to_param}/edit"

        expect(response.body).to include("Connect Stripe")
        expect(response.body).not_to include('value="site_settings"')
      end
    end

    # The Attribution screen is linked from every dashboard on purpose — the
    # unconnected state is what explains why to connect — so a customer reaches
    # it, and it must not tell them to set an environment variable on our
    # servers.
    describe "the attribution screen" do
      let(:user) { create(:user) }
      let(:account) { create(:account) }
      let(:site) { create(:site, account: account) }

      before do
        create(:membership, account: account, user: user, role: "owner")
        sign_in user
      end

      it "says it is coming rather than naming an env var, on the hosted service" do
        allow(Tastatur).to receive_messages(revenue_enabled?: false, self_hosted?: false)

        get "/sites/#{site.to_param}/attribution"

        expect(response.body).to include("not available yet")
        expect(response.body).to include(revenue_path)
        expect(response.body).not_to include("STRIPE_CONNECT_CLIENT_ID")
      end

      it "keeps the operator's instructions on a self-hosted instance" do
        allow(Tastatur).to receive_messages(revenue_enabled?: false, self_hosted?: true)

        get "/sites/#{site.to_param}/attribution"

        expect(response.body).to include("STRIPE_CONNECT_CLIENT_ID")
      end
    end
  end

  describe "joining" do
    it "stores the address and sends a confirmation" do
      expect { join(email: "reader@example.com") }
        .to change(WaitlistSignup, :count).by(1)
        .and change { ActionMailer::Base.deliveries.size }.by(1)

      expect(response).to redirect_to("/revenue")
      expect(flash[:notice]).to include("Check your inbox")
    end

    # THE ENUMERATION PROPERTY. Three different things happen inside — a new
    # signup, an address already confirmed, one mailed a minute ago — and the
    # response has to be the same for all three, or this form answers "is this
    # person on the list" about somebody else.
    it "answers identically for an address already on the list" do
      create(:waitlist_signup, :confirmed, email: "member@example.com")

      join(email: "member@example.com")
      confirmed_response = [response.status, flash[:notice]]

      join(email: "brand-new@example.com")

      expect([response.status, flash[:notice]]).to eq(confirmed_response)
    end

    it "sends nothing for an address that already confirmed" do
      create(:waitlist_signup, :confirmed, email: "member@example.com")

      expect { join(email: "member@example.com") }
        .not_to change { ActionMailer::Base.deliveries.size }
    end

    it "says so when the address is not one" do
      join(email: "not-an-address")

      expect(response).to redirect_to("/revenue")
      expect(flash[:alert]).to be_present
      expect(WaitlistSignup.count).to be_zero
    end

    # The form is on three pages; a submission from any of them comes back to
    # the one it was sent from.
    it "returns to the page it was submitted from" do
      post "/waitlist", params: { waitlist_signup: { email: "reader@example.com", source: "pricing_page" } },
                        headers: { "HTTP_REFERER" => "http://www.example.com/pricing" }

      expect(response).to redirect_to("http://www.example.com/pricing")
    end
  end

  describe "confirming" do
    before { join(email: "reader@example.com") }

    it "puts the address on the list" do
      get "/waitlist/confirm/#{emailed_token}"

      expect(response).to have_http_status(:ok)
      expect(WaitlistSignup.sole).to be_confirmed
    end

    it "names the address it confirmed and offers the way off" do
      token = emailed_token
      get "/waitlist/confirm/#{token}"

      expect(response.body).to include("reader@example.com")
      expect(response.body).to include("/waitlist/leave/#{token}")
    end

    # Mail clients prefetch, people click twice, and neither is an error worth
    # showing somebody a failure page over.
    it "is idempotent" do
      token = emailed_token
      get "/waitlist/confirm/#{token}"
      confirmed_at = WaitlistSignup.sole.confirmed_at

      get "/waitlist/confirm/#{token}"

      expect(response).to have_http_status(:ok)
      expect(WaitlistSignup.sole.confirmed_at).to eq(confirmed_at)
    end

    it "refuses a token that was never issued" do
      get "/waitlist/confirm/#{SecureRandom.urlsafe_base64(32)}"

      expect(response).to have_http_status(:not_found)
      expect(WaitlistSignup.sole).not_to be_confirmed
    end

    # The expired page says nothing about whether the address exists — and it
    # offers the form, because joining again is the actual way forward.
    it "offers a way back rather than a dead end" do
      get "/waitlist/confirm/#{SecureRandom.urlsafe_base64(32)}"

      expect(response.body).to include('action="/waitlist"')
    end
  end

  describe "leaving" do
    let!(:signup) { create(:waitlist_signup, :confirmed, email: "member@example.com", token: "leave-me") }

    # THE PREFETCH TRAP. Mail clients and security scanners fetch every URL in a
    # message. If the link removed the row, somebody could be taken off the list
    # without ever seeing a page, and the first they would know of it is never
    # hearing from us.
    it "deletes nothing on a GET" do
      expect { get "/waitlist/leave/leave-me" }.not_to change(WaitlistSignup, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("member@example.com")
    end

    it "deletes the row on the DELETE, rather than marking it unsubscribed" do
      expect { delete "/waitlist/leave/leave-me" }.to change(WaitlistSignup, :count).by(-1)

      expect(response).to redirect_to("/revenue")
      expect(flash[:notice]).to include("deleted")
    end

    it "refuses an unknown token" do
      delete "/waitlist/leave/#{SecureRandom.urlsafe_base64(32)}"

      expect(response).to have_http_status(:not_found)
      expect(WaitlistSignup.count).to eq(1)
    end

    it "is a dead link once used, and says nothing about why" do
      delete "/waitlist/leave/leave-me"

      get "/waitlist/leave/leave-me"

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include("member@example.com")
    end
  end

  # The list is a promise about the future, so the pages that describe the
  # feature must not read as though it already exists.
  describe "what the marketing pages now claim" do
    it "says the feature is not available on the revenue page" do
      get "/revenue"

      expect(response.body).to include("not available yet")
      expect(response.body).not_to include("Start measuring<")
    end

    it "says it in the markdown twin as well" do
      get "/revenue.md"

      expect(response.body).to include("not shipped yet")
    end

    it "says it in the docs section that documents the API" do
      get "/docs"

      expect(response.body).to include("not available yet")
    end
  end
end
