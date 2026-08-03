require "rails_helper"

RSpec.describe Funnel do
  let(:site) { create(:site) }

  describe "steps" do
    it "requires at least two" do
      expect(build(:funnel, site: site, steps: [{ name: "Only", match_value: "/" }])).not_to be_valid
    end

    it "renumbers them contiguously whatever order they were built in" do
      funnel = create(:funnel, site: site, steps: [{ name: "A", match_value: "/a" },
                                                   { name: "B", match_value: "/b" },
                                                   { name: "C", match_value: "/c" }])

      funnel.funnel_steps.second.mark_for_destruction
      funnel.save!

      expect(funnel.reload.funnel_steps.map(&:position)).to eq([1, 2])
    end
  end

  # A step is satisfied by ANY of its conditions. One is the ordinary case, and
  # is what every step used to be when the matcher lived in three columns on the
  # step itself.
  describe "a step's conditions" do
    let(:funnel) do
      create(:funnel, site: site, steps: [
               { name: "Landed", match_value: "/" },
               { name: "Signed up", matches: [{ match_value: "/welcome" },
                                              { kind: "event", match_value: "Signup" }] }
             ])
    end

    it "keeps each one's own kind and match type" do
      conditions = funnel.funnel_steps.last.conditions

      expect(conditions.map(&:kind)).to eq(%w[pageview event])
      expect(conditions.map(&:match_value)).to eq(["/welcome", "Signup"])
    end

    it "numbers them from one" do
      expect(funnel.funnel_steps.last.conditions.map(&:position)).to eq([1, 2])
    end

    it "refuses a step with nothing to match" do
      step = funnel.funnel_steps.first
      step.conditions.each(&:mark_for_destruction)

      expect(step).not_to be_valid
      expect(step.errors[:conditions].first).to include("must match between")
    end

    it "refuses more alternatives than a step may hold" do
      step = funnel.funnel_steps.first
      (FunnelStep::MAX_CONDITIONS + 1).times do |i|
        step.conditions.build(kind: "pageview", match_value: "/#{i}", match_type: "exact")
      end

      expect(step).not_to be_valid
    end

    it "renumbers what is left when one is removed" do
      step = funnel.funnel_steps.last
      step.conditions.first.mark_for_destruction
      step.save!

      expect(step.reload.conditions.map(&:position)).to eq([1])
      expect(step.conditions.map(&:match_value)).to eq(["Signup"])
    end

    it "goes with the step" do
      step = funnel.funnel_steps.last

      expect { step.destroy! }.to change(FunnelStepCondition, :count).by(-2)
    end

    # What the report prints under a step's name. An event name is qualified
    # because a custom event called "/welcome" and the /welcome page are
    # different things.
    it "reads as a list of alternatives" do
      expect(funnel.funnel_steps.last.summary).to eq("/welcome or event: Signup")
    end
  end

  describe "nested attributes from the form" do
    # The spare blank row the form renders is a blank step wrapped around a
    # blank condition. Judging emptiness by the step's own attributes alone
    # would call it filled in — a step's own field is just a name — and every
    # save would fail on it, which is the bug this rule exists to prevent.
    it "ignores a spare row whose only condition is blank" do
      funnel = site.funnels.new(
        name: "Signup flow", window_seconds: 86_400,
        funnel_steps_attributes: {
          "0" => { "name" => "Landed",
                   "conditions_attributes" => { "0" => { "kind" => "pageview", "match_value" => "/",
                                                         "match_type" => "exact" } } },
          "1" => { "name" => "Priced",
                   "conditions_attributes" => { "0" => { "kind" => "pageview", "match_value" => "/pricing",
                                                         "match_type" => "exact" } } },
          "2" => { "name" => "",
                   "conditions_attributes" => { "0" => { "kind" => "pageview", "match_value" => "",
                                                         "match_type" => "exact" } } }
        }
      )

      expect(funnel).to be_valid
      expect(funnel.funnel_steps.size).to eq(2)
    end

    it "keeps a row that has a match value but no name, so the error names the real problem" do
      funnel = site.funnels.new(
        name: "Signup flow", window_seconds: 86_400,
        funnel_steps_attributes: {
          "0" => { "name" => "Landed",
                   "conditions_attributes" => { "0" => { "kind" => "pageview", "match_value" => "/",
                                                         "match_type" => "exact" } } },
          "1" => { "name" => "",
                   "conditions_attributes" => { "0" => { "kind" => "pageview", "match_value" => "/pricing",
                                                         "match_type" => "exact" } } }
        }
      )

      expect(funnel).not_to be_valid
      expect(funnel.errors.full_messages.join).to include("Funnel steps name can't be blank")
    end
  end
end
