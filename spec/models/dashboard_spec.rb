require "rails_helper"

RSpec.describe Dashboard do
  let(:site) { create(:site) }

  describe "validations" do
    it "requires a name, unique per site" do
      expect(build(:dashboard, site: site, name: "")).not_to be_valid

      create(:dashboard, site: site, name: "Marketing")
      expect(build(:dashboard, site: site, name: "Marketing")).not_to be_valid
      expect(build(:dashboard, name: "Marketing")).to be_valid
    end

    it "requires between MIN_WIDGETS and MAX_WIDGETS widgets" do
      expect(build(:dashboard, site: site, widgets: [])).not_to be_valid

      too_many = Array.new(Dashboard::MAX_WIDGETS + 1) { { kind: "stat", metric: "visitors" } }
      expect(build(:dashboard, site: site, widgets: too_many)).not_to be_valid
    end

    # Validation runs BEFORE Rails destroys marked records, so the count has to
    # ignore them — the FunnelStep lesson, one level up.
    it "counts widgets marked for destruction as gone" do
      dashboard = create(:dashboard, site: site)
      dashboard.dashboard_widgets.first.mark_for_destruction

      expect(dashboard).not_to be_valid
      expect(dashboard.errors[:dashboard_widgets].join).to include("between")
    end
  end

  describe "renumbering" do
    it "makes positions contiguous regardless of what the form submitted" do
      dashboard = build(:dashboard, site: site, widgets: [])
      dashboard.dashboard_widgets.build(position: 7, kind: "stat", metric: "visitors")
      dashboard.dashboard_widgets.build(position: 3, kind: "timeseries")

      dashboard.valid?

      expect(dashboard.dashboard_widgets.map(&:position)).to eq([1, 2])
    end
  end

  describe "the per-site cap" do
    before { stub_const("Dashboard::MAX_PER_SITE", 2) }

    it "refuses creating past the cap" do
      2.times { create(:dashboard, site: site) }

      over = build(:dashboard, site: site)
      expect(over).not_to be_valid
      expect(over.errors[:base].join).to include("2 dashboards")
    end

    # The cap governs adding, never keeping — same rule as the site limit.
    it "still saves a dashboard that already exists" do
      dashboards = 2.times.map { create(:dashboard, site: site) }
      stub_const("Dashboard::MAX_PER_SITE", 1)

      expect(dashboards.first.update(name: "Renamed")).to be(true)
    end
  end

  describe "deletion" do
    # A share link scoped to this dashboard must die with it. Falling back to
    # the default dashboard would silently widen what a distributed URL shows.
    it "destroys the share links that point at it, and only those" do
      dashboard = create(:dashboard, site: site)
      scoped = create(:shared_link, site: site, dashboard: dashboard)
      unscoped = create(:shared_link, site: site)

      dashboard.destroy!

      expect(SharedLink.exists?(scoped.id)).to be(false)
      expect(SharedLink.exists?(unscoped.id)).to be(true)
    end

    it "is destroyed with its site" do
      dashboard = create(:dashboard, site: site)
      Sites::Delete.call(site: site)

      expect(described_class.exists?(dashboard.id)).to be(false)
    end
  end
end
