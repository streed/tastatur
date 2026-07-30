require "rails_helper"

# A payload the validation contract refused used to vanish completely: the endpoint
# answered 202, dropped the event, and recorded nothing anywhere. A developer whose
# beacon was malformed — a relative URL, revenue with no currency, an oversized
# props hash — got silence from every direction, and a broken integration was
# indistinguishable from no traffic.
#
# The 202 stays, because a distinguishable response is what lets someone probe for
# valid tokens. What changed is that the site's owner can see it happened.
RSpec.describe "Rejected events", type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user) }
  let!(:membership) { create(:membership, account: account, user: user, role: "owner") }
  let(:site) { create(:site, account: account, domain: "example.com") }
  let(:chrome) { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/131.0.0.0 Safari/537.36" }

  def post_event(payload)
    post "/api/event",
         params: payload.to_json,
         headers: { "CONTENT_TYPE" => "text/plain", "HTTP_USER_AGENT" => chrome }
  end

  describe "counting" do
    it "records the field that failed" do
      post_event(s: site.public_token, u: "/not-absolute")

      expect(site.rejection_counts(since: 1.hour.ago)).to include(invalid_u: 1)
    end

    it "still answers 202" do
      post_event(s: site.public_token, u: "/not-absolute")

      expect(response).to have_http_status(:accepted)
    end

    it "records revenue sent without a currency" do
      post_event(s: site.public_token, u: "https://example.com/x", n: "buy", v: 100)

      expect(site.rejection_counts(since: 1.hour.ago)).to include(invalid_c: 1)
    end

    # Otherwise the counter is an unbounded write keyed by anything a stranger sends.
    it "records nothing for a token that does not exist" do
      post_event(s: "0" * Site::TOKEN_LENGTH, u: "/not-absolute")

      expect(site.rejection_counts(since: 1.hour.ago)).to be_empty
    end

    it "records nothing for a well-formed event" do
      post_event(s: site.public_token, u: "https://example.com/fine")

      expect(site.rejection_counts(since: 1.hour.ago)).to be_empty
    end

    # `counts_for` used to iterate a hardcoded list of two reasons, so anything else
    # was written to Redis and never read back — which is precisely what happened
    # when contract failures started being recorded.
    it "reports reasons it was not written to know about" do
      Ingest::RejectionCounter.record(site_id: site.id, reason: "some_future_reason")

      expect(site.rejection_counts(since: 1.hour.ago)).to include(some_future_reason: 1)
    end

    it "still reports the hostname reasons" do
      post_event(s: site.public_token, u: "https://somewhere-else.example.org/x")

      expect(site.rejection_counts(since: 1.hour.ago)).to include(hostname_mismatch: 1)
    end
  end

  describe "the site settings page" do
    before { sign_in user }

    it "renders when there is nothing to report" do
      get edit_site_path(site)

      expect(response).to have_http_status(:ok)
    end

    it "renders the malformed-payload breakdown, in words rather than contract keys" do
      post_event(s: site.public_token, u: "/not-absolute")

      get edit_site_path(site)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Malformed")
      expect(response.body).to include("page URL")
      expect(response.body).not_to include("invalid_u")
    end

    # A reason with no occurrences is absent from the hash rather than zero, so the
    # view has to cope with a missing key instead of assuming every reason is present.
    it "renders when only some reasons have fired" do
      post_event(s: site.public_token, u: "https://somewhere-else.example.org/x")

      get edit_site_path(site)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Wrong hostname")
    end

    # THE FAILURE THIS EXAMPLE EXISTS TO PREVENT.
    #
    # `counts_for` discovers reasons rather than reading a list, and this page used
    # to undo that by naming two of them and bucketing `invalid_*`. So the first new
    # reason — a full plan allowance — made the whole "Rejected events" card appear
    # showing "Wrong hostname 0 / Wrong origin 0" and nothing else: a site owner
    # whose events were being refused was shown a card that said nothing was.
    #
    # The card now iterates whatever occurred, so this is also the example that
    # keeps the NEXT reason after this one visible.
    it "explains a rejection for a full plan allowance, rather than showing two zeroes" do
      account.update!(event_limit_override: 0)
      Billing::EventQuota.clear!

      post_event(s: site.public_token, u: "https://example.com/pricing")
      expect(site.rejection_counts(since: 1.hour.ago)).to include(plan_limit: 1)

      get edit_site_path(site)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Over plan limit")
      expect(response.body).to include("monthly event allowance")
      expect(response.body).to include(billing_path)
      expect(response.body).not_to include("plan_limit")
    end
  end
end
