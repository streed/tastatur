require "rails_helper"

RSpec.describe Analytics::FunnelReport do
  let(:site) { create(:site, :no_suppression) }
  let(:period) { Analytics::Period.parse("30d", site: site) }

  let(:funnel) do
    create(:funnel, site: site, window_seconds: 86_400, steps: [
             { name: "Landed", match_value: "/" },
             { name: "Priced", match_value: "/pricing" },
             { name: "Signed up", kind: "event", match_value: "Signup" }
           ])
  end

  before { delete_all_events }

  def report
    described_class.call(funnel: funnel, period: period).value!
  end

  # A single visitor walking the whole funnel in order.
  def complete_funnel(visitor, base: 3.hours.ago)
    create_event(site, visitor: visitor, path: "/",        at: base)
    create_event(site, visitor: visitor, path: "/pricing", at: base + 1.minute)
    create_event(site, visitor: visitor, path: "/pricing", event_name: "Signup", at: base + 2.minutes)
  end

  describe "counting steps" do
    it "counts a completed funnel at every step" do
      complete_funnel("v1")

      result = report
      expect(result.steps.map(&:visitors)).to eq([1, 1, 1])
      expect(result.entered).to eq(1)
      expect(result.completed).to eq(1)
      expect(result.overall_rate).to eq(100.0)
    end

    it "reports drop-off between steps" do
      complete_funnel("v1")
      # Two more visitors who only reach step 1.
      create_event(site, visitor: "v2", path: "/", at: 2.hours.ago)
      create_event(site, visitor: "v3", path: "/", at: 2.hours.ago)

      result = report
      expect(result.steps.map(&:visitors)).to eq([3, 1, 1])
      expect(result.steps[1].dropoff).to eq(2)
      expect(result.steps[1].dropoff_rate).to eq(66.7)
      expect(result.overall_rate).to eq(33.3)
    end

    it "does not count a visitor who never entered" do
      create_event(site, visitor: "v9", path: "/pricing", at: 2.hours.ago)
      expect(report.entered).to be_zero
    end
  end

  describe "step ordering" do
    # THE CASE THAT MOTIVATES THE QUERY DESIGN.
    #
    # This visitor reaches /pricing, backtracks to /, then returns to /pricing
    # and converts. They genuinely completed the funnel in order. The obvious
    # implementation — MIN(occurred_at) FILTER (WHERE step n) per visitor, then
    # check the timestamps increase — records their FIRST /pricing hit, which
    # precedes their first /, and drops them entirely.
    it "counts a visitor who backtracked and then completed in order" do
      base = 3.hours.ago
      create_event(site, visitor: "v1", path: "/pricing", at: base)
      create_event(site, visitor: "v1", path: "/",        at: base + 1.minute)
      create_event(site, visitor: "v1", path: "/pricing", at: base + 2.minutes)
      create_event(site, visitor: "v1", path: "/pricing", event_name: "Signup", at: base + 3.minutes)

      expect(report.steps.map(&:visitors)).to eq([1, 1, 1])
      expect(report.completed).to eq(1)
    end

    it "does not count steps reached only before the previous step" do
      base = 3.hours.ago
      # Signup happens BEFORE pricing is ever seen, and never again after.
      create_event(site, visitor: "v1", path: "/",        at: base)
      create_event(site, visitor: "v1", path: "/pricing", event_name: "Signup", at: base + 1.minute)
      create_event(site, visitor: "v1", path: "/pricing", at: base + 2.minutes)

      result = report
      expect(result.steps.map(&:visitors)).to eq([1, 1, 0])
      expect(result.completed).to be_zero
    end
  end

  describe "the completion window" do
    it "excludes a visitor who took longer than the window" do
      funnel.update!(window_seconds: 3600)
      base = 5.hours.ago
      create_event(site, visitor: "v1", path: "/",        at: base)
      create_event(site, visitor: "v1", path: "/pricing", at: base + 2.hours)

      expect(report.steps.map(&:visitors)).to eq([1, 0, 0])
    end

    it "includes a visitor who finished inside the window" do
      funnel.update!(window_seconds: 3600)
      complete_funnel("v1", base: 4.hours.ago)

      expect(report.steps.map(&:visitors)).to eq([1, 1, 1])
    end
  end

  describe "isolation" do
    it "ignores another site's traffic" do
      other = create(:site, :no_suppression)
      complete_funnel("v1")
      create_event(other, visitor: "v1", path: "/", at: 2.hours.ago)

      expect(report.entered).to eq(1)
    end

    it "ignores events outside the reporting period" do
      complete_funnel("v1", base: 90.days.ago)
      expect(report.entered).to be_zero
    end
  end

  describe "honesty about the identity lifetime" do
    it "flags a window longer than the identifier survives" do
      funnel.update!(window_seconds: 7.days.to_i)
      expect(funnel.window_exceeds_identity_lifetime?).to be(true)
    end

    it "does not flag a window inside it" do
      funnel.update!(window_seconds: 6.hours.to_i)
      expect(funnel.window_exceeds_identity_lifetime?).to be(false)
    end
  end

  # A step is satisfied by ANY of its conditions. This is what lets one funnel
  # describe a flow that branches — two checkout pages, a page and an event that
  # both mean "signed up" — instead of being split into one funnel per branch,
  # which cannot be added back together because a visitor who took both is in
  # both.
  describe "a step with alternatives" do
    let(:funnel) do
      create(:funnel, site: site, steps: [
               { name: "Landed", match_value: "/" },
               { name: "Signed up", matches: [{ match_value: "/welcome" },
                                              { kind: "event", match_value: "Signup" }] }
             ])
    end

    it "counts a visitor who matched the first alternative" do
      create_event(site, visitor: "v1", path: "/",        at: 3.hours.ago)
      create_event(site, visitor: "v1", path: "/welcome", at: 3.hours.ago + 1.minute)

      expect(report.steps.map(&:visitors)).to eq([1, 1])
    end

    it "counts a visitor who matched the other one" do
      create_event(site, visitor: "v1", path: "/", at: 3.hours.ago)
      create_event(site, visitor: "v1", path: "/pricing", event_name: "Signup", at: 3.hours.ago + 1.minute)

      expect(report.steps.map(&:visitors)).to eq([1, 1])
    end

    # The step is a set, not a sum: someone who did both is one visitor who
    # reached it, which is the thing two separate funnels cannot report.
    it "counts a visitor who matched both exactly once" do
      base = 3.hours.ago
      create_event(site, visitor: "v1", path: "/",        at: base)
      create_event(site, visitor: "v1", path: "/welcome", at: base + 1.minute)
      create_event(site, visitor: "v1", path: "/welcome", event_name: "Signup", at: base + 2.minutes)

      expect(report.steps.map(&:visitors)).to eq([1, 1])
      expect(report.completed).to eq(1)
    end

    it "does not count a visitor who matched neither" do
      create_event(site, visitor: "v1", path: "/",       at: 3.hours.ago)
      create_event(site, visitor: "v1", path: "/thanks", at: 3.hours.ago + 1.minute)

      expect(report.steps.map(&:visitors)).to eq([1, 0])
    end

    # Kind is per alternative, and it still separates the two namespaces: a
    # custom event NAMED "/welcome" is not the /welcome page.
    it "does not let an event satisfy a pageview alternative" do
      create_event(site, visitor: "v1", path: "/", at: 3.hours.ago)
      create_event(site, visitor: "v1", path: "/x", event_name: "/welcome", at: 3.hours.ago + 1.minute)

      expect(report.steps.map(&:visitors)).to eq([1, 0])
    end

    it "reaches the step at whichever alternative came first, not the declared one" do
      # The window is measured from the step's own timestamp, so a funnel whose
      # third step follows within the hour depends on which of these counts.
      funnel.funnel_steps.last.tap do |step|
        step.conditions.create!(position: 3, kind: "pageview", match_value: "/tour", match_type: "exact")
      end

      base = 3.hours.ago
      create_event(site, visitor: "v1", path: "/",        at: base)
      create_event(site, visitor: "v1", path: "/tour",    at: base + 1.minute)
      create_event(site, visitor: "v1", path: "/welcome", at: base + 2.hours)

      expect(report.steps.map(&:visitors)).to eq([1, 1])
    end

    it "matches each alternative with its own match type" do
      funnel.funnel_steps.last.conditions.create!(position: 3, kind: "pageview",
                                                  match_value: "/docs/", match_type: "prefix")

      create_event(site, visitor: "v1", path: "/",             at: 3.hours.ago)
      create_event(site, visitor: "v1", path: "/docs/install", at: 3.hours.ago + 1.minute)

      expect(report.steps.map(&:visitors)).to eq([1, 1])
    end
  end

  describe "validation" do
    it "refuses a funnel with fewer than two steps" do
      one_step = build(:funnel, site: site, steps: [{ name: "Only", match_value: "/" }])
      expect(one_step).not_to be_valid
    end

    # Only reachable by writing rows around the model, but the two shapes a
    # predicate could take for a step that matches nothing — everything or
    # nothing — are both a report that quietly means something else.
    it "refuses to report a step with nothing to match" do
      funnel.funnel_steps.first.conditions.delete_all

      expect(described_class.call(funnel: funnel.reload, period: period))
        .to eq(Dry::Monads::Failure(:step_without_a_match))
    end
  end
end
