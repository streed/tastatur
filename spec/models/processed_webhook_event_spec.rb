require "rails_helper"

RSpec.describe ProcessedWebhookEvent do
  describe ".claim" do
    it "returns a receipt the first time an event is seen" do
      receipt = described_class.claim(event_id: "evt_1", event_type: "invoice.paid")

      expect(receipt).to be_persisted
      expect(receipt.processed_at).to be_present
      expect(receipt.provider).to eq("stripe")
    end

    # THE UNIQUE INDEX IS THE GUARANTEE, NOT A RUBY CHECK.
    #
    # An `exists?` followed by a create would let two concurrent deliveries of the
    # same event both pass the check — and a retry arriving alongside the original is
    # exactly when that happens. Here the database arbitrates: both insert, one gets
    # RecordNotUnique, and `claim` turns that into nil rather than an exception the
    # caller has to know about.
    it "returns nil rather than raising when the event is already claimed" do
      described_class.create!(provider: "stripe", event_id: "evt_1",
                              event_type: "invoice.paid", processed_at: Time.current)

      expect(described_class.claim(event_id: "evt_1", event_type: "invoice.paid")).to be_nil
      expect(described_class.count).to eq(1)
    end

    it "allows the same id from a different provider" do
      described_class.claim(event_id: "evt_1", event_type: "invoice.paid")

      expect(described_class.claim(event_id: "evt_1", event_type: "something.else", provider: "other"))
        .to be_persisted
    end
  end

  describe ".prune!" do
    # Stripe stops retrying after three days, so a receipt older than the window
    # cannot be matched against anything and is only taking up space.
    it "removes receipts past the retention window and keeps the rest" do
      old = described_class.create!(provider: "stripe", event_id: "evt_old", event_type: "invoice.paid",
                                    processed_at: 40.days.ago)
      recent = described_class.create!(provider: "stripe", event_id: "evt_new", event_type: "invoice.paid",
                                       processed_at: 1.day.ago)

      expect(described_class.prune!).to eq(1)
      expect(described_class.exists?(old.id)).to be(false)
      expect(described_class.exists?(recent.id)).to be(true)
    end
  end

  # Nothing routable, so no public identifier — and deliberately no payload column.
  # A Stripe event body carries the customer's email, address and card details, none
  # of which is needed to answer "have I already handled this?".
  it "stores no personal data" do
    expect(described_class.column_names)
      .to contain_exactly("id", "provider", "event_id", "event_type", "processed_at",
                          "created_at", "updated_at")
  end
end
