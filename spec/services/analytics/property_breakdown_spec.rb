require "rails_helper"

# Custom event properties, finally readable.
#
# `tastatur('event', 'Signup', { props: { plan: 'pro' } })` was accepted,
# validated, indexed and written to the `props` column from the beginning, and
# read back by nothing at all. The install page documents the call, so following
# the documentation produced data that no screen could show. These specs pin the
# reading side: what a row counts, what the percentages are against, and that
# k-anonymity reaches this panel as surely as it reaches the other eight.
RSpec.describe Analytics::PropertyBreakdown do
  let(:site) { create(:site, timezone: "Etc/UTC", k_anonymity_threshold: 0) }
  let(:period) { Analytics::Period.new("7d", site: site) }
  let(:filters) { Analytics::Filters.new("event" => "Signup") }
  let(:base) { 2.days.ago.change(hour: 12) }

  def report(with: filters)
    described_class.call(site: site, period: period, filters: with).value!
  end

  describe "grouping" do
    before do
      create_event(site, visitor: "a", event_name: "Signup", props: { "plan" => "pro", "source" => "docs" }, at: base)
      create_event(site, visitor: "b", event_name: "Signup", props: { "plan" => "pro", "source" => "blog" },
                         at: base + 1.minute)
      create_event(site, visitor: "c", event_name: "Signup", props: { "plan" => "free" }, at: base + 2.minutes)
    end

    it "returns one result per property key" do
      expect(report.map(&:first)).to contain_exactly("plan", "source")
    end

    # Two visitors on pro, one on free — the panel's whole reason to exist.
    it "counts distinct visitors per value" do
      plan = report.to_h.fetch("plan")

      expect(plan.rows.map { |row| [row.value, row.visitors] })
        .to eq([["pro", 2], ["free", 1]])
    end

    # `plan` was seen by three visitors and `source` by two, so `plan` leads. A
    # site owner should not have to scroll past a property they set once to
    # reach the one they look at.
    it "orders properties by how many visitors sent them" do
      expect(report.map(&:first)).to eq(%w[plan source])
    end

    # The property panels answer a question about one event. Without the event
    # condition, a Signup carrying plan=pro and a Cancelled carrying plan=pro
    # would land in the same row, which is not a fact about anything.
    it "honours the event filter it is scoped by" do
      create_event(site, visitor: "d", event_name: "Cancelled", props: { "plan" => "enterprise" },
                         at: base + 3.minutes)

      expect(report.to_h.fetch("plan").rows.map(&:value)).not_to include("enterprise")
    end
  end

  # THE DENOMINATOR, which is the same trap Analytics::Breakdown documents.
  #
  # One visitor can fire the same event twice with two different values, so the
  # rows legitimately sum past the number of visitors. Dividing by the row sum
  # would count that visitor twice and understate every percentage on the panel.
  describe "percentages" do
    before do
      create_event(site, visitor: "a", event_name: "Signup", props: { "plan" => "pro" }, at: base)
      create_event(site, visitor: "a", event_name: "Signup", props: { "plan" => "free" }, at: base + 1.minute)
      create_event(site, visitor: "b", event_name: "Signup", props: { "plan" => "pro" }, at: base + 2.minutes)
    end

    it "measures each row against distinct visitors in scope, not the sum of the rows" do
      rows = report.to_h.fetch("plan").rows.to_h { |row| [row.value, row.percentage] }

      # Two visitors in scope. pro was sent by both (100%), free by one (50%) —
      # summing the rows would have given a denominator of three and 66%/33%.
      expect(rows).to eq("pro" => 100.0, "free" => 50.0)
    end
  end

  describe "k-anonymity" do
    let(:site) { create(:site, timezone: "Etc/UTC", k_anonymity_threshold: 3) }

    before do
      4.times { |i| create_event(site, visitor: "big-#{i}", event_name: "Signup", props: { "plan" => "pro" }, at: base) }
      3.times { |i| create_event(site, visitor: "mid-#{i}", event_name: "Signup", props: { "plan" => "team" }, at: base) }
      create_event(site, visitor: "solo", event_name: "Signup", props: { "plan" => "enterprise" }, at: base)
    end

    # A property value can be a single person by construction — the customer
    # picks the key, so `user_id` is as likely to arrive as `plan`. This panel
    # is the first in the application where that is true, which is why the
    # suppression is shared code rather than reimplemented here.
    it "withholds a value seen by fewer than k visitors" do
      expect(report.to_h.fetch("plan").rows.map(&:value)).not_to include("enterprise")
    end

    # Complementary suppression: hiding only `enterprise` would leave it
    # derivable as total − the visible rows, so the smallest survivor goes too.
    it "withholds a second row so the first cannot be derived by subtraction" do
      result = report.to_h.fetch("plan")

      expect(result.rows.map(&:value)).to eq(["pro"])
      expect(result.suppressed_rows).to eq(2)
      expect(result.suppressed_visitors).to eq(4)
    end
  end

  describe "what it ignores" do
    it "returns nothing when the matching events carry no properties" do
      create_event(site, visitor: "a", event_name: "Signup", at: base)

      expect(report).to be_empty
    end

    it "ignores events outside the period" do
      create_event(site, visitor: "a", event_name: "Signup", props: { "plan" => "pro" }, at: 30.days.ago)

      expect(report).to be_empty
    end

    it "ignores another site's events" do
      other = create(:site, timezone: "Etc/UTC", k_anonymity_threshold: 0)
      create_event(other, visitor: "a", event_name: "Signup", props: { "plan" => "pro" }, at: base)

      expect(report).to be_empty
    end

    # jsonb_each_text raises "cannot deconstruct a scalar" on a jsonb that is not
    # an object, and it would raise inside the dashboard's own query — a 500 on
    # the page, from a single malformed row. IngestEventContract requires a hash
    # so this is unreachable through ingest today, which is exactly why the guard
    # needs a spec: nothing else would notice if it were removed.
    it "survives a props value that is not an object" do
      create_event(site, visitor: "a", event_name: "Signup", props: 42, at: base)
      create_event(site, visitor: "b", event_name: "Signup", props: { "plan" => "pro" }, at: base + 1.minute)

      expect(report.to_h.fetch("plan").rows.map(&:value)).to eq(["pro"])
    end
  end

  # Drilling into a property value narrows the whole dashboard, which is the
  # point of showing the rows at all.
  describe "under a property filter" do
    before do
      create_event(site, visitor: "a", event_name: "Signup",
                         props: { "plan" => "pro", "source" => "docs" }, at: base)
      create_event(site, visitor: "b", event_name: "Signup",
                         props: { "plan" => "free", "source" => "blog" }, at: base + 1.minute)
    end

    it "restricts the other properties to events matching the filtered one" do
      narrowed = filters.with("props:plan", "pro")

      expect(report(with: narrowed).to_h.fetch("source").rows.map(&:value)).to eq(["docs"])
    end
  end
end
