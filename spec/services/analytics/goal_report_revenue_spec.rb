require "rails_helper"

# Revenue used to be `SUM(revenue_cents)` over every matching event regardless of
# currency, so a site taking euros and dollars had them added together and shown as
# one figure with no unit. Measured on the fixture below, the old query produced
# 22300 — a number that is not an amount of anything.
#
# The tracking API takes a currency on every revenue event and the documented
# example uses EUR, so mixed currencies are the expected case.
RSpec.describe Analytics::GoalReport do
  let(:site) { create(:site, timezone: "Etc/UTC") }
  let(:period) { Analytics::Period.new("7d", site: site) }
  let!(:goal) do
    create(:goal, site: site, kind: "event", match_type: "exact", match_value: "Purchase")
  end

  def purchase(currency:, cents:, visitor:)
    create_event(site, path: "/checkout", at: 2.hours.ago, visitor: visitor,
                       event_name: "Purchase", currency: currency, revenue_cents: cents)
  end

  def row
    described_class.call(site: site, period: period).value!.find { |r| r.goal.id == goal.id }
  end

  context "with several currencies" do
    before do
      purchase(currency: "EUR", cents: 4_900, visitor: "a")
      purchase(currency: "EUR", cents: 2_500, visitor: "b")
      purchase(currency: "USD", cents: 9_900, visitor: "c")
      purchase(currency: "JPY", cents: 5_000, visitor: "d")
    end

    it "keeps each currency separate" do
      expect(row.revenue_by_currency).to eq("EUR" => 7_400, "USD" => 9_900, "JPY" => 5_000)
    end

    it "never produces a cross-currency total" do
      expect(row.revenue_by_currency.values.sum).to eq(22_300)
      expect(row).not_to respond_to(:revenue_cents)
    end

    it "orders by amount so the currency that matters leads" do
      expect(row.revenue.map(&:first)).to eq(%w[USD EUR JPY])
    end

    it "still counts conversions and visitors across all of them" do
      expect(row.conversions).to eq(4)
      expect(row.visitors).to eq(4)
    end
  end

  context "with a conversion that carries no money" do
    before do
      purchase(currency: "EUR", cents: 4_900, visitor: "a")
      create_event(site, path: "/checkout", at: 2.hours.ago, visitor: "b", event_name: "Purchase")
    end

    it "counts it as a conversion" do
      expect(row.conversions).to eq(2)
    end

    # A NULL currency forms its own group in the GROUPING SETS query, and it must
    # not surface as a currency called nothing.
    it "does not invent a currency for it" do
      expect(row.revenue_by_currency.keys).to eq(["EUR"])
    end
  end

  context "with no revenue at all" do
    before { create_event(site, path: "/checkout", at: 2.hours.ago, visitor: "a", event_name: "Purchase") }

    it "reports no revenue" do
      expect(row.revenue?).to be(false)
      expect(row.revenue_by_currency).to be_empty
    end
  end

  describe "formatting" do
    include DashboardHelper
    include ActionView::Helpers::NumberHelper

    it "renders two decimal places for an ordinary currency" do
      expect(money_amount("EUR", 4_900)).to eq("49.00 EUR")
    end

    # Getting this wrong shows ¥49.00 for a ¥4,900 sale.
    it "renders zero-decimal currencies whole" do
      expect(money_amount("JPY", 4_900)).to eq("4,900 JPY")
    end

    it "names the currency rather than guessing a symbol" do
      # "$" is ambiguous across a dozen currencies.
      expect(money_amount("usd", 123_456)).to eq("1,234.56 USD")
    end
  end
end
