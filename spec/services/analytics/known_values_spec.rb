require "rails_helper"

RSpec.describe Analytics::KnownValues do
  let(:site) { create(:site, :no_suppression) }

  def call(target = site)
    described_class.call(site: target).value!
  end

  describe "what it offers" do
    before do
      create_events(site, count: 3, path: "/pricing", visitor_prefix: "p", at: 1.hour.ago)
      create_event(site, path: "/about", visitor: "a1", at: 1.hour.ago)
      create_event(site, path: "/about", visitor: "a2", at: 1.hour.ago)
      create_event(site, event_name: "Signup", path: "/pricing", visitor: "s1", at: 1.hour.ago)
    end

    it "returns the recorded paths with their visitor counts" do
      expect(call.paths.map(&:value)).to contain_exactly("/pricing", "/about")
    end

    it "orders them most-visited first, which is the useful default for an empty query" do
      expect(call.paths.map(&:value).first).to eq("/pricing")
      expect(call.paths.first.visitors).to eq(4)
    end

    # The whole reason the event list is a separate dimension rather than a
    # DISTINCT over event_name: otherwise it is one enormous "pageview" row.
    it "lists custom events without the pageview pseudo-event" do
      expect(call.events.map(&:value)).to eq(["Signup"])
    end

    it "reports the window it looked at, for the sentence under the field" do
      expect(call.days).to eq(30)
    end
  end

  describe "values another site recorded" do
    let(:other) { create(:site, :no_suppression) }

    it "are never offered" do
      create_event(other, path: "/secret-admin", visitor: "x", at: 1.hour.ago)

      expect(call.paths).to be_empty
    end
  end

  describe "events outside the lookback window" do
    it "are dropped, so a page deleted last quarter is not still suggested" do
      create_event(site, path: "/retired", visitor: "v1", at: 200.days.ago)
      create_event(site, path: "/current", visitor: "v2", at: 2.days.ago)

      expect(call.paths.map(&:value)).to eq(["/current"])
    end
  end

  # This is the load-bearing one. The picker is a breakdown — values plus
  # distinct-visitor counts — so /privacy's threshold promise covers it, and it
  # would be a straightforward way to read rows the Top pages panel withholds.
  describe "k-anonymity" do
    let(:site) { create(:site, k_anonymity_threshold: 5) }

    before do
      create_events(site, count: 8, path: "/popular", visitor_prefix: "pop", at: 1.hour.ago)
      create_events(site, count: 6, path: "/known", visitor_prefix: "kn", at: 1.hour.ago)
      create_event(site, path: "/rare", visitor: "one-person", at: 1.hour.ago)
    end

    it "withholds a value seen by fewer visitors than the site's threshold" do
      expect(call.paths.map(&:value)).not_to include("/rare")
    end

    it "counts what it withheld, so the form can say so instead of looking empty" do
      # /rare is under the threshold, and complementary suppression takes the
      # smallest surviving row with it — otherwise /rare is recoverable by
      # subtraction. See Analytics::Suppression.
      expect(call.withheld).to eq(2)
      expect(call.paths.map(&:value)).to eq(["/popular"])
    end

    it "reports the threshold that did it" do
      expect(call.threshold).to eq(5)
    end

    it "leaves everything in place when the site has suppression turned off" do
      site.update!(k_anonymity_threshold: 0)

      expect(call.paths.map(&:value)).to include("/rare")
      expect(call).not_to be_withheld
    end
  end

  describe "the payload handed to the browser" do
    before do
      create_event(site, path: "/pricing", visitor: "v1", at: 1.hour.ago)
      create_event(site, event_name: "Signup", path: "/pricing", visitor: "v1", at: 1.hour.ago)
    end

    it "is keyed by the kind column the form switches on" do
      expect(call.payload).to eq(
        "pageview" => [{ "v" => "/pricing", "n" => 1 }],
        "event" => [{ "v" => "Signup", "n" => 1 }]
      )
    end
  end

  describe "a site with nothing recorded" do
    it "succeeds with empty lists rather than failing" do
      result = call

      expect(result).not_to be_any
      expect(result.paths).to be_empty
      expect(result.events).to be_empty
    end
  end
end
