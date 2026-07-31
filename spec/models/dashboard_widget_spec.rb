require "rails_helper"

RSpec.describe DashboardWidget do
  let(:site) { create(:site) }
  let(:dashboard) { create(:dashboard, site: site) }

  def widget(**attrs)
    dashboard.dashboard_widgets.build(position: 2, **attrs)
  end

  describe "per-kind validation" do
    it "requires a known metric on a stat widget" do
      expect(widget(kind: "stat", metric: "visitors")).to be_valid
      expect(widget(kind: "stat", metric: "clicks")).not_to be_valid
      expect(widget(kind: "stat", metric: nil)).not_to be_valid
    end

    it "requires a known dimension on a breakdown widget" do
      expect(widget(kind: "breakdown", dimension: "page")).to be_valid
      expect(widget(kind: "breakdown", dimension: "path")).not_to be_valid
      expect(widget(kind: "breakdown", dimension: nil)).not_to be_valid
    end

    it "bounds the row limit" do
      expect(widget(kind: "breakdown", dimension: "page", row_limit: 0)).not_to be_valid
      expect(widget(kind: "breakdown", dimension: "page", row_limit: 51)).not_to be_valid
    end

    it "refuses an unknown kind" do
      expect(widget(kind: "sparkline")).not_to be_valid
    end
  end

  describe "the funnel reference" do
    let(:funnel) { create(:funnel, site: site) }

    it "requires a funnel on a new funnel widget" do
      expect(widget(kind: "funnel", funnel: funnel)).to be_valid
      expect(widget(kind: "funnel")).not_to be_valid
    end

    it "refuses a funnel belonging to another site" do
      foreign = create(:funnel)
      expect(widget(kind: "funnel", funnel: foreign)).not_to be_valid
    end

    it "requires a funnel when the kind CHANGES to funnel" do
      saved = widget(kind: "stat", metric: "visitors")
      saved.save!

      saved.kind = "funnel"
      expect(saved).not_to be_valid
    end

    # The FK nullifies funnel_id when the funnel is deleted. That widget is a
    # legitimate row rendering an explanatory empty state, and it must not
    # block re-saving the rest of the dashboard.
    it "does not block a widget whose funnel was deleted out from under it" do
      saved = widget(kind: "funnel", funnel: funnel)
      saved.save!

      funnel.destroy!

      expect(saved.reload.funnel_id).to be_nil
      expect(saved).to be_valid
    end

    describe "#funnel_public_id" do
      it "round-trips through the public identifier, never the primary key" do
        w = widget(kind: "funnel")
        w.funnel_public_id = funnel.public_id

        expect(w.funnel).to eq(funnel)
        expect(w.funnel_public_id).to eq(funnel.public_id)

        w.funnel_public_id = ""
        expect(w.funnel).to be_nil
      end
    end
  end

  describe "clearing irrelevant configuration" do
    # The no-JS form submits every per-kind field; stored config must mean
    # what the kind says it means.
    it "nulls whatever the chosen kind does not use" do
      w = widget(kind: "timeseries", metric: "visitors", dimension: "page",
                 funnel: create(:funnel, site: site))
      w.valid?

      expect(w.metric).to be_nil
      expect(w.dimension).to be_nil
      expect(w.funnel).to be_nil
    end
  end

  describe "filters" do
    it "drops unknown keys and blank values at the boundary" do
      w = widget(kind: "stat", metric: "visitors",
                 filters: { "page" => "/x", "bogus" => "nope", "country" => "" })
      w.save!

      expect(w.reload.filters).to eq("page" => "/x")
    end

    it "round-trips property filters in the nested props shape" do
      w = widget(kind: "stat", metric: "visitors",
                 filters: { "event" => "Signup", "props" => { "plan" => "pro" } })
      w.save!

      expect(w.reload.filters).to eq("event" => "Signup", "props" => { "plan" => "pro" })
      expect(w.saved_filters.applied).to eq("event" => "Signup", "props:plan" => "pro")
    end

    describe "#filter_pairs_attributes=" do
      it "rebuilds the whole hash from the submitted pairs" do
        w = widget(kind: "stat", metric: "visitors", filters: { "page" => "/old" })

        w.filter_pairs_attributes = {
          "sentinel" => { "dimension" => "", "value" => "" },
          "0" => { "dimension" => "source", "value" => "Google" }
        }

        expect(w.filters).to eq("source" => "Google")
      end

      # The sentinel is what makes deleting the LAST filter stick: it keeps
      # the parameter present so this writer runs on an all-pairs-removed
      # submission.
      it "empties the filters when only the sentinel arrives" do
        w = widget(kind: "stat", metric: "visitors", filters: { "page" => "/old" })

        w.filter_pairs_attributes = { "sentinel" => { "dimension" => "", "value" => "" } }

        expect(w.filters).to eq({})
      end
    end

    describe "#filter_pairs" do
      it "exposes the stored hash as editable pairs" do
        w = widget(kind: "stat", metric: "visitors", filters: { "page" => "/x" })

        expect(w.filter_pairs.map { |p| [p.dimension, p.value] }).to eq([["page", "/x"]])
      end
    end
  end

  describe "#display_title" do
    it "prefers the author's title, then falls back per kind" do
      funnel = create(:funnel, site: site, name: "Signup flow")

      expect(widget(kind: "stat", metric: "bounce_rate", title: "Custom").display_title).to eq("Custom")
      expect(widget(kind: "stat", metric: "bounce_rate").display_title).to eq("Bounce rate")
      expect(widget(kind: "timeseries").display_title).to eq("Traffic")
      # A dimension the default dashboard has a panel for borrows that panel's
      # title; one it does not falls back to the filter label.
      expect(widget(kind: "breakdown", dimension: "page").display_title).to eq("Top pages")
      expect(widget(kind: "breakdown", dimension: "utm_source").display_title).to eq("UTM source")
      expect(widget(kind: "goals").display_title).to eq("Goal conversions")
      expect(widget(kind: "funnel", funnel: funnel).display_title).to eq("Signup flow")
      expect(widget(kind: "funnel").display_title).to eq("Funnel")
    end
  end
end
