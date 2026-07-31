require "rails_helper"

RSpec.describe Revenue::Checkout do
  describe ".metadata" do
    it "prefixes every key so it cannot collide with the customer's own" do
      result = described_class.metadata(source: "reddit", campaign: "launch")

      expect(result.keys).to all(start_with("tst_"))
      expect(result["tst_source"]).to eq("reddit")
    end

    it "omits fields that were not supplied, rather than sending empty strings" do
      result = described_class.metadata(source: "reddit")

      expect(result.keys).to eq(["tst_source"])
    end

    it "serialises a time to ISO 8601" do
      at = Time.utc(2026, 6, 15, 12, 0, 0)

      expect(described_class.metadata(first_seen_at: at)["tst_first_seen_at"]).to eq(at.iso8601)
    end

    it "ignores fields outside the supported set" do
      result = described_class.metadata(source: "reddit", secret: "hunter2")

      expect(result.values).not_to include("hunter2")
    end

    # A value over Stripe's 500-character limit fails the WHOLE Checkout Session
    # — meaning our analytics helper would break the customer's checkout, the
    # single worst thing this library could do.
    it "truncates rather than letting Stripe refuse the session" do
      result = described_class.metadata(campaign: "x" * 900)

      expect(result["tst_campaign"].length).to eq(500)
    end

    it "is empty for nothing at all" do
      expect(described_class.metadata(nil)).to eq({})
      expect(described_class.metadata({})).to eq({})
    end
  end

  describe ".extract_attribution" do
    it "round-trips what metadata produced" do
      original = { source: "reddit", medium: "social", campaign: "launch", landing_path: "/pricing" }

      expect(described_class.extract_attribution(described_class.metadata(original))).to eq(original)
    end

    it "reads string keys, which is how they come back from jsonb" do
      expect(described_class.extract_attribution("tst_source" => "reddit")).to eq(source: "reddit")
    end

    it "ignores the customer's own metadata" do
      result = described_class.extract_attribution("order_id" => "1234", "tst_source" => "reddit")

      expect(result).to eq(source: "reddit")
    end

    it "parses the timestamp back into a Time" do
      at = Time.utc(2026, 6, 15, 12, 0, 0)
      result = described_class.extract_attribution(described_class.metadata(first_seen_at: at))

      expect(result[:first_seen_at]).to be_within(1.second).of(at)
    end

    # This value came from a third party's metadata via a customer's application.
    # An unparseable one must not fail a webhook — the rest of the attribution is
    # still good, and refusing all of it to keep the part that does not matter is
    # the wrong trade.
    it "drops an unparseable timestamp and keeps the rest" do
      result = described_class.extract_attribution("tst_source" => "reddit",
                                                   "tst_first_seen_at" => "not a date")

      expect(result[:source]).to eq("reddit")
      expect(result).not_to have_key(:first_seen_at)
    end

    it "is empty for metadata that carries none of ours" do
      expect(described_class.extract_attribution("order_id" => "1234")).to eq({})
      expect(described_class.extract_attribution(nil)).to eq({})
    end
  end
end
