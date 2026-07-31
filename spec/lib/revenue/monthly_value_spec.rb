require "rails_helper"

RSpec.describe Revenue::MonthlyValue do
  def item(unit_amount:, interval:, interval_count: 1, quantity: 1)
    { price: { unit_amount: unit_amount, recurring: { interval: interval, interval_count: interval_count } },
      quantity: quantity }
  end

  describe ".for_item" do
    it "passes a monthly price through unchanged" do
      expect(described_class.for_item(item(unit_amount: 4_000, interval: "month"))).to eq(4_000)
    end

    # THE ERROR THIS WHOLE MODULE EXISTS TO PREVENT. An annual plan reported at
    # its full price turns every January into a cliff on the revenue chart,
    # followed by eleven months of apparent collapse.
    it "divides a yearly price by twelve" do
      expect(described_class.for_item(item(unit_amount: 48_000, interval: "year"))).to eq(4_000)
    end

    it "uses 52 weeks a year, not 48" do
      # 1000/wk * 52 / 12 = 4333, not 4000. The naive "four weeks a month" is
      # wrong by 8%, which is larger than most businesses' growth rate.
      expect(described_class.for_item(item(unit_amount: 1_000, interval: "week"))).to eq(4_333)
    end

    it "uses 365 days a year" do
      expect(described_class.for_item(item(unit_amount: 100, interval: "day"))).to eq(3_041)
    end

    it "honours interval_count, so a two-monthly plan is worth half" do
      expect(described_class.for_item(item(unit_amount: 8_000, interval: "month", interval_count: 2))).to eq(4_000)
    end

    it "multiplies by quantity" do
      expect(described_class.for_item(item(unit_amount: 1_000, interval: "month", quantity: 5))).to eq(5_000)
    end

    it "is zero for a price with no recurring block" do
      expect(described_class.for_item({ price: { unit_amount: 5_000 }, quantity: 1 })).to eq(0)
    end

    it "is zero for a nil item rather than raising" do
      expect(described_class.for_item(nil)).to eq(0)
    end
  end

  describe "rounding" do
    # Truncation, always downward, so a reported MRR is never higher than what is
    # actually collected. $100/year is 833.33 cents a month.
    it "rounds down rather than to nearest" do
      expect(described_class.for_item(item(unit_amount: 10_000, interval: "year"))).to eq(833)
    end

    it "never overstates, across a spread of awkward yearly prices" do
      (1..200).each do |dollars|
        cents = dollars * 100
        monthly = described_class.for_item(item(unit_amount: cents, interval: "year"))

        expect(monthly * 12).to be <= cents
      end
    end
  end

  describe ".for_subscription" do
    it "sums every recurring item" do
      subscription = { items: { data: [item(unit_amount: 4_000, interval: "month"),
                                       item(unit_amount: 12_000, interval: "year")] } }

      expect(described_class.for_subscription(subscription)).to eq(5_000)
    end

    # The single-item version under-reports a subscription with an add-on by the
    # entire value of the add-on — silently, and only for the customers paying most.
    it "does not stop at the first item" do
      subscription = { items: { data: [item(unit_amount: 1_000, interval: "month"),
                                       item(unit_amount: 2_000, interval: "month"),
                                       item(unit_amount: 3_000, interval: "month")] } }

      expect(described_class.for_subscription(subscription)).to eq(6_000)
    end

    it "ignores a one-off line item on a subscription invoice" do
      subscription = { items: { data: [item(unit_amount: 4_000, interval: "month"),
                                       { price: { unit_amount: 50_000 }, quantity: 1 }] } }

      expect(described_class.for_subscription(subscription)).to eq(4_000)
    end

    it "is zero for a subscription with no items" do
      expect(described_class.for_subscription({ items: { data: [] } })).to eq(0)
      expect(described_class.for_subscription({})).to eq(0)
    end
  end

  describe "an interval Stripe adds later" do
    it "returns zero and says so loudly rather than silently dropping a customer" do
      expect(Rails.logger).to receive(:error).with(/unknown Stripe billing interval/)

      expect(described_class.monthly(4_000, "fortnight", 1)).to eq(0)
    end
  end
end
