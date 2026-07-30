require "rails_helper"

# Driven at the Rack env directly, because the interesting inputs cannot be
# expressed any other way: Rack::Test parses the URL with `URI.parse`, which
# rejects `%zz` before the application is called, so a request spec that tried
# these would be testing the test harness. A real HTTP client has no such
# scruples and sends the bytes.
RSpec.describe Middleware::SanitizeIngestQuery do
  # The downstream app records what it was handed, so each example can assert on
  # the query string the rest of the stack would actually see.
  let(:seen) { {} }

  let(:app) do
    recorder = seen
    described_class.new(lambda do |env|
      recorder[:query] = env["QUERY_STRING"]
      [200, {}, ["ok"]]
    end)
  end

  def call(path, query)
    app.call("PATH_INFO" => path, "QUERY_STRING" => query)
    seen[:query]
  end

  # Mirrors the check the middleware makes, so an example asserting "downstream
  # can parse this" is not just asserting a string comparison.
  def parseable?(query)
    ActionDispatch::ParamBuilder.from_query_string(query)
    true
  rescue StandardError
    false
  end

  describe "input Rails would reject" do
    # Every one of these produced a 400 with a full exception report, on an
    # endpoint documented to be indistinguishable whatever it is sent.
    {
      "truncated percent escape" => "s=%",
      "invalid percent escape" => "s=%zz",
      "unparseable key" => "%=1",
      "incomplete multi-byte escape" => "s=%E0%A4%A",
      "several bad pairs" => "a=%zz&b=%&c=%E0"
    }.each do |label, query|
      it "makes a #{label} parseable" do
        expect(parseable?(query)).to be(false), "precondition: #{query.inspect} should be unparseable"

        expect(parseable?(call("/api/event", query))).to be(true)
      end
    end

    it "drops only the offending pair" do
      expect(call("/api/event", "bad=%zz&s=abc123&u=https%3A%2F%2Fx.example.com%2Fp"))
        .to eq("s=abc123&u=https%3A%2F%2Fx.example.com%2Fp")
    end

    it "keeps pair order and duplicates among the survivors" do
      expect(call("/api/event", "a=1&bad=%&a=2&b=3")).to eq("a=1&a=2&b=3")
    end

    it "abandons the query string when no subset can be parsed" do
      # An over-deep nesting is a property of the whole string rather than of one
      # pair, so pair-by-pair filtering cannot rescue it and the fallback applies.
      #
      # 120 levels, not 32: Rack::Utils.param_depth_limit is 32 but ActionDispatch
      # does its own parsing here with a limit of 100, and it is the latter that
      # decides whether this request 400s. An earlier version of this spec used 14
      # and passed for the wrong reason.
      deep = "a#{(1..120).map { |i| "[#{i}]" }.join}=1"

      expect(parseable?(deep)).to be(false), "precondition: 120 levels should exceed the limit"
      expect(call("/api/event", deep)).to eq("")
    end

    it "applies to the pixel path too" do
      expect(parseable?(call("/api/pixel", "s=%zz"))).to be(true)
    end
  end

  describe "input Rails accepts" do
    it "passes a valid query string through untouched" do
      query = "s=abc123&u=https%3A%2F%2Fx.example.com%2Fp&w=1440"

      expect(call("/api/event", query)).to eq(query)
    end

    it "leaves an empty query string alone" do
      expect(call("/api/event", "")).to eq("")
    end

    it "does not corrupt legitimately encoded multi-byte characters" do
      query = "u=https%3A%2F%2Fx.example.com%2F%E6%97%A5%E6%9C%AC%E8%AA%9E"

      expect(call("/api/event", query)).to eq(query)
    end
  end

  # Scoped on purpose. Everywhere else, a malformed query string is a client bug
  # and a 400 is the honest and useful answer; swallowing it globally would hide
  # real problems and silently change behaviour across the whole application.
  describe "paths that are not ingest" do
    ["/", "/dashboard", "/api/other", "/sites/abc"].each do |path|
      it "leaves #{path} untouched so it still fails loudly" do
        expect(call(path, "s=%zz")).to eq("s=%zz")
      end
    end
  end
end
