require "rails_helper"

# The contract between lib/tracker/t.js and Revenue::Checkout.
#
# THESE TWO FILES HAVE TO AGREE AND NOTHING ELSE MAKES THEM. The tracker builds
# the metadata hash in a browser; `Revenue::Checkout.extract_attribution` reads it
# back off a Stripe webhook, in Ruby, weeks later. They share a key prefix and a
# field list and are edited by different people for different reasons.
#
# Every way they can disagree fails silently. A renamed prefix means
# `extract_attribution` matches nothing, so every customer arrives with no
# attribution and the report quietly says "Direct" for all of them. A field the
# tracker sends and Ruby does not declare is dropped on the floor. Neither raises,
# neither shows up in a log, and the symptom appears a month later as a revenue
# report that is confidently wrong.
#
# A behavioural test is not available: there is no JavaScript runtime in the
# application container, so the suite cannot execute the tracker. So this reads the
# source, exactly as spec/privacy_invariants_spec.rb does, and for the same reason
# — the failure is new code in a new place quietly disagreeing, which no
# behavioural spec can reach.
RSpec.describe "The tracker's attribution contract" do
  let(:source) { Rails.root.join("lib/tracker/t.js").read }

  it "uses the same metadata prefix Ruby reads back" do
    expect(source).to include("var META_PREFIX = '#{Revenue::Checkout::PREFIX}'")
  end

  it "clips values at the same limit Ruby truncates to" do
    expect(source).to include("var META_MAX = #{Revenue::Checkout::MAX_VALUE_LENGTH}")
  end

  it "exposes both halves of the public API" do
    expect(source).to include("tastatur.attribution = attribution")
    expect(source).to include("tastatur.checkoutMetadata = checkoutMetadata")
  end

  # The tracker derives source/medium/campaign/term/content by slicing "utm_" off
  # the parameter names, and adds landing_path, referrer_host and first_seen_at by
  # hand. Every one of those has to be a field Ruby declares, or it is silently
  # dropped between the browser and the report.
  it "sends only fields Revenue::Checkout declares" do
    utm_fields = source[/var UTM = \[(.*?)\]/m, 1].to_s.scan(/'utm_(\w+)'/).flatten.map(&:to_sym)
    hand_added = %i[landing_path first_seen_at referrer_host]

    expect(utm_fields).not_to be_empty, "could not parse the UTM list out of t.js"
    expect(utm_fields + hand_added).to all(be_in(Revenue::Checkout::FIELDS))
  end

  # THE BUG THIS PINS. `referrer_host` is what the tracker sends for every visit
  # carrying no UTM tags — all organic and word-of-mouth traffic. Omitted from
  # FIELDS it was dropped on the way into Stripe, so the customer created from
  # checkout.session.completed had nothing to classify and fell back to Direct:
  # every tagged campaign attributed correctly, every untagged referral silently
  # relabelled as direct.
  it "carries referrer_host, which untagged traffic depends on entirely" do
    expect(Revenue::Checkout::FIELDS).to include(:referrer_host)
  end

  describe "a payload the tracker would actually produce" do
    # Copied from a real run of t.js against
    # https://shop.example.com/pricing with a Hacker News referrer and no UTM tags.
    let(:from_browser) do
      { "tst_landing_path" => "/pricing",
        "tst_first_seen_at" => "2026-06-15T12:00:00.000Z",
        "tst_referrer_host" => "news.ycombinator.com" }
    end

    it "round-trips into attribution Ruby understands" do
      attribution = Revenue::Checkout.extract_attribution(from_browser)

      expect(attribution[:referrer_host]).to eq("news.ycombinator.com")
      expect(attribution[:landing_path]).to eq("/pricing")
      expect(attribution[:first_seen_at]).to be_a(Time)
    end

    # The end of the whole chain: an untagged Hacker News visit that paid must
    # land on the "Hacker News" row, the same one the anonymous pageview counted.
    it "resolves to the channel the events pipeline uses" do
      site = create(:site)
      attribution = Revenue::Checkout.extract_attribution(from_browser)

      customer = Revenue::IdentifyCustomer.call(
        site: site, params: { stripe_customer_id: "cus_1", attribution: attribution }
      ).value!

      expect(customer.attribution_source).to eq("Hacker News")
    end
  end
end
