require "rails_helper"

# The filter allowlist is a security boundary, and custom event properties are
# the one filter that cannot be expressed as an allowlist — the customer invents
# the key. So the boundary moves: the key becomes a bind parameter and the value
# has to be a scalar or it is dropped. These specs pin both halves, plus the
# round trip through a URL that makes a filtered dashboard shareable.
RSpec.describe Analytics::Filters do
  describe "the dimension allowlist" do
    it "keeps a known dimension" do
      expect(described_class.new("page" => "/pricing").applied).to eq("page" => "/pricing")
    end

    # The whole point: an arbitrary key must never reach the SQL builder.
    it "drops an unknown key" do
      expect(described_class.new("visitor_hash" => "abc")).to be_empty
    end

    it "drops a blank value" do
      expect(described_class.new("page" => "")).to be_empty
    end
  end

  describe "custom event properties" do
    subject(:filters) { described_class.new("props" => { "plan" => "pro" }) }

    it "stores them under the reserved prefix so they cannot collide with a dimension" do
      expect(filters.applied).to eq("props:plan" => "pro")
      expect(filters).to be_property_scoped
      expect(filters.properties).to eq("plan" => "pro")
    end

    # The property name is bound, never interpolated. It is the only part of any
    # filter whose spelling the customer chooses, so it is the only one that
    # could carry SQL if this were ever built by concatenation.
    it "binds the property name as a parameter rather than interpolating it" do
      sql, binds = filters.to_sql

      expect(sql).to eq("props ->> ? = ?")
      expect(binds).to eq(%w[plan pro])
    end

    it "prefixes the column when the query needs a table alias" do
      sql, = filters.to_sql(table: "e")

      expect(sql).to eq("e.props ->> ? = ?")
    end

    # A name of a customer's own choosing is shown verbatim: `plan`, not `Plan`.
    # Humanising is right for our vocabulary (`utm_source`) and wrong for theirs.
    it "labels a property with the key exactly as it was sent" do
      expect(filters.label_for("props:plan")).to eq("plan")
      expect(described_class.new.label_for("utm_source")).to eq("UTM source")
    end

    it "combines with a dimension filter" do
      combined = described_class.new("event" => "Signup", "props" => { "plan" => "pro" })
      sql, binds = combined.to_sql

      expect(sql).to eq("event_name = ? AND props ->> ? = ?")
      expect(binds).to eq(%w[Signup plan pro])
    end
  end

  # `props: {}` permits arbitrary nesting, because the keys cannot be named in
  # advance. That makes this the place the shape is actually constrained.
  describe "what a property filter refuses" do
    it "drops a value that arrived as an array" do
      expect(described_class.new("props" => { "plan" => %w[a b] })).to be_empty
    end

    it "drops a value that arrived as a nested hash" do
      expect(described_class.new("props" => { "plan" => { "nested" => "x" } })).to be_empty
    end

    it "drops a blank value" do
      expect(described_class.new("props" => { "plan" => "" })).to be_empty
    end

    it "drops a blank key" do
      expect(described_class.new("props" => { "  " => "pro" })).to be_empty
    end

    # A key longer than the ingest contract allows cannot exist in the data, so
    # such a filter is either noise or an attempt to make the query expensive.
    it "drops a key longer than the ingest contract permits" do
      too_long = "k" * (IngestEventContract::MAX_PROP_KEY + 1)

      expect(described_class.new("props" => { too_long => "x" })).to be_empty
    end

    it "caps how many property filters can be applied at once" do
      many = (1..25).to_h { |i| ["key#{i}", "value"] }

      expect(described_class.new("props" => many).properties.size)
        .to eq(described_class::MAX_PROPERTY_FILTERS)
    end

    it "truncates an over-long value rather than sending it to the database" do
      filters = described_class.new("props" => { "plan" => "x" * 900 })

      expect(filters.properties["plan"].length).to eq(described_class::MAX_VALUE)
    end
  end

  # Filter state lives entirely in the URL — that is what makes a filtered
  # dashboard shareable and survivable across the back button. A property filter
  # that could not round-trip would break on the first page reload.
  describe "the URL round trip" do
    it "renders properties back into the nested shape params can permit" do
      filters = described_class.new("event" => "Signup", "props" => { "plan" => "pro" })

      expect(filters.to_param).to eq("event" => "Signup", "props" => { "plan" => "pro" })
    end

    it "omits the props key entirely when no property is filtered" do
      expect(described_class.new("event" => "Signup").to_param).to eq("event" => "Signup")
    end

    it "survives being rebuilt from its own to_param" do
      original = described_class.new("event" => "Signup", "props" => { "plan" => "pro" })

      expect(described_class.new(original.to_param).applied).to eq(original.applied)
    end

    # ActionController::Parameters, the shape that actually arrives.
    it "permits the nested props hash out of request parameters" do
      params = ActionController::Parameters.new(
        page: "/pricing", props: { plan: "pro" }, site_id: "9", secret: "no"
      )

      expect(described_class.from_params(params).applied)
        .to eq("page" => "/pricing", "props:plan" => "pro")
    end
  end

  # Drilling into a property row builds the filter through the same helpers the
  # dimension panels use, so the prefixed key has to work with both.
  describe "with and without" do
    it "adds a property filter by its prefixed key" do
      filters = described_class.new("event" => "Signup").with("props:plan", "pro")

      expect(filters.properties).to eq("plan" => "pro")
    end

    it "removes one without disturbing the others" do
      filters = described_class.new("event" => "Signup", "props" => { "plan" => "pro", "tier" => "2" })

      expect(filters.without("props:plan").applied).to eq("event" => "Signup", "props:tier" => "2")
    end
  end
end
