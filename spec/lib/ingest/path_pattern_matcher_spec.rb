require "rails_helper"

RSpec.describe Ingest::PathPatternMatcher do
  before { described_class.clear_cache! }

  def apply(patterns, path)
    described_class.for(patterns).apply(path.split("/"))
  end

  it "rewrites a declared parameter segment to its placeholder" do
    matched, consumed = apply(["/sites/:token"], "/sites/FB1WRC5D0PFFHKZ5")
    expect(matched).to eq(["", "sites", ":token"])
    expect(consumed).to eq(3)
  end

  it "rewrites every parameter in a multi-segment pattern" do
    matched, = apply(["/blog/:year/:month/:slug"], "/blog/2025/07/hello")
    expect(matched.join("/")).to eq("/blog/:year/:month/:slug")
  end

  it "prefers a literal child over the parameter child at the same level" do
    matched, = apply(["/sites/new", "/sites/:token"], "/sites/new")
    expect(matched.join("/")).to eq("/sites/new")

    matched, = apply(["/sites/new", "/sites/:token"], "/sites/ABC123DEF456GHJ7")
    expect(matched.join("/")).to eq("/sites/:token")
  end

  it "stops at the first segment no pattern covers and reports what it consumed" do
    # Declared /sites/:token; the "/edit" tail is undeclared, so it is left to
    # the caller (PathScrubber) rather than invented.
    matched, consumed = apply(["/sites/:token"], "/sites/FB1WRC5D0PFFHKZ5/edit")
    expect(matched).to eq(["", "sites", ":token"])
    expect(consumed).to eq(3)
  end

  it "stops at the root when no declared segment matches, leaving the rest to the caller" do
    # Every pattern begins with "/", so the shared leading "" is consumed; the
    # first real segment ("docs") matches nothing, so the tail is left for
    # PathScrubber to scrub heuristically.
    matched, consumed = apply(["/sites/:token"], "/docs/getting-started")
    expect(matched).to eq([""])
    expect(consumed).to eq(1)
  end

  it "matches nothing at all when built from no patterns" do
    expect(described_class.for([])).to be_empty
    matched, consumed = apply([], "/anything/here")
    expect(matched).to eq([])
    expect(consumed).to eq(0)
  end

  it "caches the compiled matcher by pattern list" do
    expect(described_class.for(["/sites/:token"])).to be(described_class.for(["/sites/:token"]))
  end
end
