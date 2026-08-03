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
  # blank rows, keyed by index. A step's match values are one level further down
  # now — a step is satisfied by any one of its conditions — so a blank spare row
  # is a blank step wrapped around a blank condition, which is the shape the
  # reject_if rules have to see through.
  def condition_attrs(existing, spares: 0)
    rows = existing.each_with_index.to_h do |condition, i|
      [i.to_s, { "id" => condition.id.to_s, "kind" => condition.kind,
                 "match_value" => condition.match_value, "match_type" => condition.match_type }]
    end
    spares.times do |i|
      rows[(existing.size + i).to_s] =
        { "kind" => "pageview", "match_value" => "", "match_type" => "exact" }
    end
    rows
  end

  # A brand new step row, as the Add button's clone submits it.
  def step_row(name, *matches)
    conditions = matches.each_with_index.to_h do |match, i|
      [i.to_s, { "kind" => "pageview", "match_type" => "exact" }.merge(match.transform_keys(&:to_s))]
    end
    { "name" => name, "conditions_attributes" => conditions }
  end

  def step_attrs(existing, spares: 3, extra: {})
    rows = existing.each_with_index.to_h do |step, i|
      [i.to_s, { "id" => step.id.to_s, "name" => step.name,
                 "conditions_attributes" => condition_attrs(step.conditions.to_a) }]
    end
    spares.times do |i|
      rows[(existing.size + i).to_s] =
        { "name" => "", "conditions_attributes" => condition_attrs([], spares: 1) }
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
      rows["2"] = step_row("Signed up", kind: "event", match_value: "Signup")

      submit rows

      expect(response).to redirect_to(site_funnel_path(site, funnel))
      expect(funnel.reload.funnel_steps.map(&:name)).to eq(%w[Landed Priced Signed\ up])
    end

    it "adds several at once" do
      rows = step_attrs(funnel.funnel_steps.to_a)
      rows["2"] = step_row("Third", match_value: "/c")
      rows["3"] = step_row("Fourth", match_value: "/d")

      submit rows
      expect(funnel.reload.funnel_steps.count).to eq(4)
    end

    it "numbers steps contiguously even when a middle spare row is skipped" do
      rows = step_attrs(funnel.funnel_steps.to_a)
      # Fill the SECOND spare and leave the first blank.
      rows["3"] = step_row("Later", match_value: "/z")

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
      rows["2"] = step_row("Replacement", match_value: "/new")

      submit rows

      expect(funnel.reload.funnel_steps.map(&:name)).to eq(%w[Priced Replacement])
      expect(funnel.funnel_steps.map(&:position)).to eq([1, 2])
    end
  end

  # A step is satisfied by ANY of its alternatives, and they are a second nested
  # form inside the first. The rows below are what that one submits.
  describe "a step's alternatives" do
    def conditions_of(step_name)
      funnel.reload.funnel_steps.find { |step| step.name == step_name }.conditions
    end

    it "offers a control to add one" do
      get "/sites/#{site.to_param}/funnels/#{funnel.to_param}/edit"

      expect(response.body).to include("Add alternative")
      # A placeholder of its own, because the step template's clone replaces the
      # OUTER one throughout the markup it copies.
      expect(response.body).to include("NEW_CONDITION")
    end

    it "adds one to a saved step" do
      rows = step_attrs(funnel.funnel_steps.to_a)
      rows["1"]["conditions_attributes"]["1"] =
        { "kind" => "event", "match_value" => "Pricing Viewed", "match_type" => "exact" }

      submit rows

      expect(response).to redirect_to(site_funnel_path(site, funnel))
      expect(conditions_of("Priced").map(&:match_value)).to eq(["/pricing", "Pricing Viewed"])
      expect(conditions_of("Priced").map(&:position)).to eq([1, 2])
    end

    it "creates a step with alternatives in one go" do
      rows = step_attrs(funnel.funnel_steps.to_a)
      rows["2"] = step_row("Signed up",
                           { match_value: "/welcome" },
                           { kind: "event", match_value: "Signup" })

      submit rows

      expect(conditions_of("Signed up").map(&:match_value)).to eq(["/welcome", "Signup"])
      expect(conditions_of("Signed up").map(&:kind)).to eq(%w[pageview event])
    end

    it "removes the ticked one and renumbers the rest" do
      rows = step_attrs(funnel.funnel_steps.to_a)
      rows["1"]["conditions_attributes"]["1"] =
        { "kind" => "pageview", "match_value" => "/plans", "match_type" => "exact" }
      submit rows

      rows = step_attrs(funnel.reload.funnel_steps.to_a)
      rows["1"]["conditions_attributes"]["0"]["_destroy"] = "1"
      submit rows

      expect(conditions_of("Priced").map(&:match_value)).to eq(["/plans"])
      expect(conditions_of("Priced").map(&:position)).to eq([1])
    end

    # The blank spare row a step opens with must not fail the save, exactly as
    # for steps themselves — that bug, one level down.
    it "ignores a blank spare row" do
      rows = step_attrs(funnel.funnel_steps.to_a)
      rows["1"]["conditions_attributes"]["1"] =
        { "kind" => "pageview", "match_value" => "", "match_type" => "exact" }

      submit rows

      expect(response).to redirect_to(site_funnel_path(site, funnel))
      expect(conditions_of("Priced").count).to eq(1)
    end

    # ...but a step left with nothing at all to match is a step that can never
    # be reached, and saving one produces a funnel the report refuses to run.
    it "refuses a step whose only alternative was cleared" do
      rows = step_attrs(funnel.funnel_steps.to_a)
      rows["1"]["conditions_attributes"]["0"]["_destroy"] = "1"

      submit rows

      expect(response).to have_http_status(:unprocessable_content)
      expect(conditions_of("Priced").count).to eq(1)
    end

    # Otherwise the form comes back with the error and no field to answer it in.
    it "re-renders a row to type into when the last one was rejected" do
      rows = step_attrs(funnel.funnel_steps.to_a)
      rows["1"]["conditions_attributes"]["0"]["_destroy"] = "1"

      submit rows

      expect(response.body).to include("Add alternative")
      expect(response.body.scan(/\[conditions_attributes\]\[\d+\]\[match_value\]/).size).to be >= 2
    end
  end

  it "renders a clonable template row rather than pre-populated blanks" do
    get "/sites/#{site.to_param}/funnels/#{funnel.to_param}/edit"

    # A browser never submits <template> contents, so the prototype cannot reach
    # the server on its own.
    expect(response.body).to include("<template")
    expect(response.body).to include("NEW_RECORD")
    # Exactly the two saved steps, no spare blanks padding the form out. Counted
    # by the fields a real row submits: the template's are keyed by the
    # placeholder rather than a number, so they cannot be mistaken for one.
    expect(response.body.scan(/funnel_steps_attributes\]\[\d+\]\[name\]/).size).to eq(2)
    expect(response.body.scan(/funnel_steps_attributes\]\[\d+\]\[conditions_attributes\]\[\d+\]\[match_value\]/).size)
      .to eq(2)
  end
end
