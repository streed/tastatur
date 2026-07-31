require "rails_helper"

RSpec.describe Revenue::IdentifyCustomer do
  let(:site) { create(:site) }

  def identify(params)
    described_class.call(site: site, params: params)
  end

  describe "creating" do
    it "creates a customer from an external id" do
      result = identify(external_id: "user_1")

      expect(result).to be_success
      expect(result.value!.external_id).to eq("user_1")
      expect(result.value!.identified_at).to be_present
    end

    it "hashes the email and never stores it" do
      customer = identify(email: "Person@Example.COM ").value!

      expect(customer.email_hash).to eq(Digest::SHA256.hexdigest("person@example.com"))
      expect(customer.attributes.values.map(&:to_s)).not_to include(a_string_matching(/person@example/i))
    end

    it "records the first touch supplied by the application" do
      seen = 5.days.ago.change(usec: 0)
      customer = identify(external_id: "user_1",
                          attribution: { source: "reddit", medium: "social", campaign: "launch",
                                         landing_path: "/pricing", first_seen_at: seen }).value!

      expect(customer.attribution_source).to eq("reddit")
      expect(customer.attribution_campaign).to eq("launch")
      expect(customer.attribution_landing_path).to eq("/pricing")
      expect(customer.first_seen_at).to be_within(1.second).of(seen)
    end
  end

  # THE PRODUCT DECISION. An app calls identify on every sign-in, not only at
  # signup — so under last-write-wins a customer acquired from Reddit in January
  # is re-attributed to Google the first time they search their own brand name.
  # Every paid channel then decays toward zero on its own, which looks exactly
  # like a campaign that stopped working.
  describe "write-once attribution" do
    it "keeps the first source when a later call sends a different one" do
      identify(external_id: "user_1", attribution: { source: "reddit", medium: "social" })
      identify(external_id: "user_1", attribution: { source: "Google", medium: "organic" })

      customer = site.customers.find_by(external_id: "user_1")
      expect(customer.attribution_source).to eq("reddit")
      expect(customer.attribution_medium).to eq("social")
    end

    # Field by field, so an app that learns the landing path later than the source
    # can still fill the gap without being able to overwrite what is there.
    it "fills a field that was never set" do
      identify(external_id: "user_1", attribution: { source: "reddit" })
      identify(external_id: "user_1", attribution: { source: "Google", campaign: "launch" })

      customer = site.customers.find_by(external_id: "user_1")
      expect(customer.attribution_source).to eq("reddit")
      expect(customer.attribution_campaign).to eq("launch")
    end

    it "treats a stored empty string as unset rather than as attributed" do
      customer = create(:customer, site: site, external_id: "user_1", attribution_source: "")
      identify(external_id: "user_1", attribution: { source: "reddit" })

      expect(customer.reload.attribution_source).to eq("reddit")
    end
  end

  describe "first_seen_at" do
    it "moves earlier when the app finds better information" do
      identify(external_id: "user_1", attribution: { source: "x", first_seen_at: 2.days.ago })
      identify(external_id: "user_1", attribution: { source: "x", first_seen_at: 9.days.ago })

      expect(site.customers.find_by(external_id: "user_1").first_seen_at).to be_within(1.minute).of(9.days.ago)
    end

    it "never moves later" do
      identify(external_id: "user_1", attribution: { source: "x", first_seen_at: 9.days.ago })
      identify(external_id: "user_1", attribution: { source: "x", first_seen_at: 1.hour.ago })

      expect(site.customers.find_by(external_id: "user_1").first_seen_at).to be_within(1.minute).of(9.days.ago)
    end
  end

  describe "matching" do
    it "joins an existing customer by external id and fills in the Stripe id" do
      create(:customer, site: site, external_id: "user_1", stripe_customer_id: nil)

      expect { identify(external_id: "user_1", stripe_customer_id: "cus_1") }
        .not_to change { site.customers.count }

      expect(site.customers.find_by(external_id: "user_1").stripe_customer_id).to eq("cus_1")
    end

    it "joins by Stripe id when no external id is given" do
      create(:customer, site: site, external_id: "user_1", stripe_customer_id: "cus_1")

      expect { identify(stripe_customer_id: "cus_1") }.not_to change { site.customers.count }
    end

    # Repointing an existing row at a different Stripe customer would move all of
    # that person's historical revenue onto a stranger.
    it "refuses to overwrite a Stripe id that is already set" do
      create(:customer, site: site, external_id: "user_1", stripe_customer_id: "cus_original")

      identify(external_id: "user_1", stripe_customer_id: "cus_different")

      expect(site.customers.find_by(external_id: "user_1").stripe_customer_id).to eq("cus_original")
    end

    it "is scoped to the site, so two tenants may use the same external id" do
      other = create(:site)
      identify(external_id: "user_1")
      described_class.call(site: other, params: { external_id: "user_1" })

      expect(Customer.where(external_id: "user_1").count).to eq(2)
    end
  end

  # The email index is deliberately not unique: two people can share an address
  # across two of the customer's own accounts. An ambiguous match must therefore
  # be treated as no match, or a subscription gets attached to a coin flip.
  describe "an ambiguous email" do
    it "creates a new customer rather than guessing between two matches" do
      hash = Customer.hash_email("shared@example.com")
      create(:customer, site: site, external_id: "a", email_hash: hash)
      create(:customer, site: site, external_id: "b", email_hash: hash)

      expect { identify(email: "shared@example.com") }.to change { site.customers.count }.by(1)
    end

    it "matches when there is exactly one" do
      create(:customer, site: site, external_id: "a", email_hash: Customer.hash_email("one@example.com"))

      expect { identify(email: "one@example.com") }.not_to change { site.customers.count }
    end
  end

  describe "channel normalisation" do
    # The two halves of the attribution report join on these strings. A referrer
    # host on one side and a friendly name on the other produces two rows: one
    # with the visitors, one with the money.
    it "classifies a referrer host into the same name the events pipeline uses" do
      customer = identify(external_id: "user_1",
                          attribution: { referrer_host: "news.ycombinator.com" }).value!

      expect(customer.attribution_source).to eq("Hacker News")
    end

    it "resolves a subdomain to its parent" do
      customer = identify(external_id: "user_1", attribution: { referrer_host: "news.google.com" }).value!

      expect(customer.attribution_source).to eq("Google")
    end

    it "prefers an explicit source over the referrer, as a UTM tag is a statement of intent" do
      customer = identify(external_id: "user_1",
                          attribution: { source: "newsletter", referrer_host: "news.ycombinator.com" }).value!

      expect(customer.attribution_source).to eq("newsletter")
    end

    # STORED NULL, READ AS "Direct". The sentinel is applied when the row is read
    # or grouped, never when it is written — see Revenue::Channel.resolve_source.
    it "stores nothing when there is neither, and reads as Direct" do
      customer = identify(external_id: "user_1", attribution: { landing_path: "/" }).value!

      expect(customer.attribution_source).to be_nil
      expect(customer.attribution_medium).to be_nil
      expect(customer.attribution[:source]).to eq(Revenue::Channel::DIRECT)
      expect(customer.attribution[:medium]).to eq(Revenue::Channel::NONE)
    end

    # THE REGRESSION THIS PAIR EXISTS FOR. Storing a sentinel would make the
    # column non-blank, and because attribution is write-once, the real campaign
    # arriving on the next call could never fill it — leaving every customer
    # permanently attributed to "(none)" for whatever their first call omitted,
    # with a report that looked entirely plausible.
    it "never writes a sentinel into a column the caller left out" do
      customer = identify(external_id: "user_1", attribution: { source: "reddit" }).value!

      expect(customer.attribution_medium).to be_nil
      expect(customer.attribution_campaign).to be_nil
    end

    it "still accepts the real campaign on a later call" do
      identify(external_id: "user_1", attribution: { source: "reddit" })
      identify(external_id: "user_1", attribution: { campaign: "launch", medium: "social" })

      customer = site.customers.find_by(external_id: "user_1")
      expect(customer.attribution_campaign).to eq("launch")
      expect(customer.attribution_medium).to eq("social")
    end

    it "leaves an unrecognised host alone" do
      customer = identify(external_id: "user_1", attribution: { referrer_host: "blog.example.dev" }).value!

      expect(customer.attribution_source).to eq("blog.example.dev")
    end
  end

  describe "failure" do
    it "refuses a payload with no identifier at all" do
      result = identify(attribution: { source: "reddit" })

      expect(result).to be_failure
    end
  end
end
