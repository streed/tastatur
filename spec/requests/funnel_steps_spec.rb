require "rails_helper"

# Adding and removing funnel steps was completely broken, in a way that looked
# like the form doing nothing:
#
#   The edit action rendered one spare blank step row. That row failed validation
#   ("name can't be blank"), so EVERY save was rejected — an added step and a
#   removed step alike. And there was no control to add a step at all, so a new
#   funnel was stuck at exactly the two rows the form opened with.
#
# These examples drive the form over HTTP, exactly as a browser does, because a
# model-level spec would have passed throughout.
RSpec.describe "Funnel steps", type: :request do
  let(:user) { create(:user) }
  let(:account) { create(:account) }
  let(:site) { create(:site, account: account) }

  let(:funnel) do
    create(:funnel, site: site, name: "Signup flow", steps: [
             { name: "Landed", match_value: "/" },
             { name: "Priced", match_value: "/pricing" }
           ])
  end

  before do
    create(:membership, account: account, user: user, role: "owner")
    sign_in user
  end

  # Mirrors what the rendered form submits: every existing row, plus the spare
  # blank rows, keyed by index.
  def step_attrs(existing, spares: 3, extra: {})
    rows = existing.each_with_index.to_h do |step, i|
      [i.to_s, { "id" => step.id.to_s, "name" => step.name, "kind" => step.kind,
                 "match_value" => step.match_value, "match_type" => step.match_type }]
    end
    spares.times do |i|
      rows[(existing.size + i).to_s] =
        { "name" => "", "kind" => "pageview", "match_value" => "", "match_type" => "exact" }
    end
    extra.each { |k, v| rows[k] = v }
    rows
  end

  def submit(rows, name: funnel.name)
    patch "/sites/#{site.to_param}/funnels/#{funnel.to_param}",
          params: { funnel: { name: name, window_seconds: funnel.window_seconds,
                              funnel_steps_attributes: rows } }
  end

  describe "the add control" do
    it "renders an Add step button" do
      get "/sites/#{site.to_param}/funnels/#{funnel.to_param}/edit"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Add step")
    end

    it "renders it on a new funnel too, so it is not stuck at two steps" do
      get "/sites/#{site.to_param}/funnels/new"
      expect(response.body).to include("Add step")
    end

    # THE REGRESSION. Submitting unchanged used to fail on the blank row.
    it "saves cleanly when nothing was changed" do
      submit step_attrs(funnel.funnel_steps.to_a, spares: 0)

      expect(response).to redirect_to(site_funnel_path(site, funnel))
      expect(funnel.reload.funnel_steps.count).to eq(2)
    end
  end

  describe "adding a step" do
    it "adds one by filling in a spare row" do
      rows = step_attrs(funnel.funnel_steps.to_a)
      rows["2"] = { "name" => "Signed up", "kind" => "event",
                    "match_value" => "Signup", "match_type" => "exact" }

      submit rows

      expect(response).to redirect_to(site_funnel_path(site, funnel))
      expect(funnel.reload.funnel_steps.map(&:name)).to eq(%w[Landed Priced Signed\ up])
    end

    it "adds several at once" do
      rows = step_attrs(funnel.funnel_steps.to_a)
      rows["2"] = { "name" => "Third", "kind" => "pageview", "match_value" => "/c", "match_type" => "exact" }
      rows["3"] = { "name" => "Fourth", "kind" => "pageview", "match_value" => "/d", "match_type" => "exact" }

      submit rows
      expect(funnel.reload.funnel_steps.count).to eq(4)
    end

    it "numbers steps contiguously even when a middle spare row is skipped" do
      rows = step_attrs(funnel.funnel_steps.to_a)
      # Fill the SECOND spare and leave the first blank.
      rows["3"] = { "name" => "Later", "kind" => "pageview", "match_value" => "/z", "match_type" => "exact" }

      submit rows

      expect(funnel.reload.funnel_steps.map(&:position)).to eq([1, 2, 3])
      expect(funnel.funnel_steps.map(&:name)).to eq(%w[Landed Priced Later])
    end
  end

  describe "removing a step" do
    let(:funnel) do
      create(:funnel, site: site, name: "Three step", steps: [
               { name: "One", match_value: "/1" },
               { name: "Two", match_value: "/2" },
               { name: "Three", match_value: "/3" }
             ])
    end

    it "removes the ticked step" do
      existing = funnel.funnel_steps.to_a
      rows = step_attrs(existing)
      rows["1"]["_destroy"] = "1"

      submit rows

      expect(response).to redirect_to(site_funnel_path(site, funnel))
      expect(funnel.reload.funnel_steps.map(&:name)).to eq(%w[One Three])
    end

    it "renumbers what is left" do
      rows = step_attrs(funnel.funnel_steps.to_a)
      rows["1"]["_destroy"] = "1"

      submit rows
      expect(funnel.reload.funnel_steps.map(&:position)).to eq([1, 2])
    end

    it "refuses to drop below the minimum rather than saving a broken funnel" do
      rows = step_attrs(funnel.funnel_steps.to_a)
      rows["0"]["_destroy"] = "1"
      rows["1"]["_destroy"] = "1"

      submit rows

      expect(response).to have_http_status(:unprocessable_content)
      expect(funnel.reload.funnel_steps.count).to eq(3)
    end

    it "re-renders the spare rows on failure, so the form is still usable" do
      rows = step_attrs(funnel.funnel_steps.to_a)
      submit rows, name: ""

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Add step")
    end
  end

  describe "adding and removing in one save" do
    it "handles both at once" do
      existing = funnel.funnel_steps.to_a
      rows = step_attrs(existing)
      rows["0"]["_destroy"] = "1"
      rows["2"] = { "name" => "Replacement", "kind" => "pageview",
                    "match_value" => "/new", "match_type" => "exact" }

      submit rows

      expect(funnel.reload.funnel_steps.map(&:name)).to eq(%w[Priced Replacement])
      expect(funnel.funnel_steps.map(&:position)).to eq([1, 2])
    end
  end

  it "renders a clonable template row rather than pre-populated blanks" do
    get "/sites/#{site.to_param}/funnels/#{funnel.to_param}/edit"

    # A browser never submits <template> contents, so the prototype cannot reach
    # the server on its own.
    expect(response.body).to include("<template")
    expect(response.body).to include("NEW_RECORD")
    # Exactly the two saved steps, no spare blanks padding the form out.
    expect(response.body.scan(/data-nested-form-row/).size).to eq(3) # 2 real + 1 template
  end
end
