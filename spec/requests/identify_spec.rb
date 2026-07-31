require "rails_helper"

# `type: :request` is explicit because this suite deliberately does not call
# `infer_spec_type_from_file_location!` — a file under spec/requests is otherwise
# a plain example group with no `post` method. See spec/rails_helper.rb.
RSpec.describe "POST /api/v1/identify", type: :request do
  let(:site) { create(:site) }
  let!(:api_key) { create(:api_key, site: site) }

  # Accepts either `identify(external_id: "u1")` or `identify({...}, token: "...")`.
  # Ruby 3 does not fold bare keywords into a positional hash, so a plain
  # `def identify(body, token:)` rejects the first form outright.
  def identify(body = nil, token: api_key.plaintext, **rest)
    post "/api/v1/identify",
         params: (body || rest).to_json,
         headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}" }
  end

  describe "authentication" do
    it "accepts a live key" do
      identify(external_id: "user_1")

      expect(response).to have_http_status(:ok)
      expect(site.customers.find_by(external_id: "user_1")).to be_present
    end

    it "accepts the key in X-Api-Key, for clients that strip Authorization" do
      post "/api/v1/identify", params: { external_id: "user_1" }.to_json,
           headers: { "Content-Type" => "application/json", "X-Api-Key" => api_key.plaintext }

      expect(response).to have_http_status(:ok)
    end

    it "refuses a missing key" do
      post "/api/v1/identify", params: { external_id: "user_1" }.to_json,
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:unauthorized)
      expect(site.customers).to be_empty
    end

    it "refuses a revoked key" do
      plaintext = api_key.plaintext
      api_key.revoke!

      identify({ external_id: "user_1" }, token: plaintext)

      expect(response).to have_http_status(:unauthorized)
    end

    # ONE MESSAGE FOR EVERY FAILURE. A response distinguishing "no such key" from
    # "revoked" from "wrong secret" is an oracle, and tells a legitimate developer
    # nothing their own settings page does not.
    it "gives the same answer whatever is wrong with the key" do
      bodies = ["tk_nope_nope", "garbage", "tk_#{api_key.token_prefix}_wrong"].map do |token|
        identify({ external_id: "user_1" }, token: token)
        JSON.parse(response.body)
      end

      expect(bodies.uniq.length).to eq(1)
    end
  end

  # THE OPPOSITE RULE FROM THE INGEST ENDPOINT, deliberately. §12 requires
  # /api/event to answer 202 for everything, because it is called from a browser
  # by an anonymous stranger. Every caller here has already proved it holds a
  # secret, and the failure this endpoint actually has is silent — an identify
  # call that quietly does nothing produces a revenue report that is confidently
  # wrong months later.
  describe "reporting problems honestly" do
    it "names the fields that were wrong" do
      identify(attribution: { source: "reddit" })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["details"]).to be_present
    end

    it "does not answer 202 for a body it refused" do
      identify({})

      expect(response).not_to have_http_status(:accepted)
    end
  end

  describe "the response" do
    it "returns the identifiers the caller will need again" do
      identify(external_id: "user_1", stripe_customer_id: "cus_1")
      body = JSON.parse(response.body)

      expect(body["external_id"]).to eq("user_1")
      expect(body["stripe_customer_id"]).to eq("cus_1")
      expect(body["id"]).to be_present
    end

    # Echoing it invites the caller to store it back into their user record,
    # which turns our write-once field into their last-write-wins field and
    # destroys the guarantee the whole model rests on.
    it "does not echo the attribution back" do
      identify(external_id: "user_1", attribution: { source: "reddit" })

      expect(JSON.parse(response.body).keys).not_to include("attribution")
    end
  end

  describe "tenant isolation" do
    it "writes only to the site the key belongs to" do
      other = create(:site)

      identify(external_id: "user_1")

      expect(site.customers.count).to eq(1)
      expect(other.customers.count).to eq(0)
    end
  end

  describe "the email" do
    it "is hashed and never stored" do
      identify(external_id: "user_1", email: "person@example.com")

      customer = site.customers.find_by(external_id: "user_1")
      expect(customer.email_hash).to eq(Customer.hash_email("person@example.com"))
      expect(Customer.column_names).not_to include("email")
    end
  end

  describe "declared keys only" do
    # An application posting its whole user object at this endpoint is the
    # obvious thing to do, and people will. It must not result in us storing
    # their whole user object.
    it "ignores fields the contract does not declare" do
      identify(external_id: "user_1", password: "hunter2", ssn: "123-45-6789",
               attribution: { source: "reddit", internal_note: "vip" })

      customer = site.customers.find_by(external_id: "user_1")
      expect(customer.attributes.values.map(&:to_s)).not_to include("hunter2", "123-45-6789", "vip")
    end
  end

  describe "usage tracking" do
    it "records that the key was used" do
      expect { identify(external_id: "user_1") }
        .to change { api_key.reload.last_used_at }.from(nil)
    end
  end
end
