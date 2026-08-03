require "rails_helper"

RSpec.describe Ingest::PathScrubber do
  def scrub(url, patterns: []) = described_class.call(URI.parse(url), patterns: patterns)
  def params(url) = described_class.query_params(URI.parse(url))

  describe "personal data in the path" do
    # These are the cases that make the difference between "we store no personal
    # data" being true and being a claim we have not earned. Customer sites put
    # all of this in their URLs routinely.
    it "replaces an email address segment" do
      expect(scrub("https://e.com/users/alice@example.com/settings")).to eq("/users/:email/settings")
    end

    it "replaces a UUID segment" do
      expect(scrub("https://e.com/invoice/7f3a91c2-4b8e-4c1a-9f2d-1e5b8a7c3d90"))
        .to eq("/invoice/:uuid")
    end

    # public_id is a UUID v4 for most models (CLAUDE.md §10), so a routed record
    # is a UUID in a path segment. It must collapse whatever its case and wherever
    # it sits, and a following segment must survive.
    it "replaces a UUID regardless of case and keeps the rest of the path" do
      expect(scrub("https://e.com/users/3F2504E0-4F89-41D3-9A0C-0305E82C3301/settings"))
        .to eq("/users/:uuid/settings")
    end

    it "replaces a long opaque token segment" do
      expect(scrub("https://e.com/reset/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9abcdef"))
        .to eq("/reset/:token")
    end

    it "replaces a hex digest segment" do
      expect(scrub("https://e.com/f/9f86d081884c7d659a2feaa0c55ad015")).to eq("/f/:hash")
    end

    it "collapses a numeric id so the breakdown is useful rather than a million rows" do
      expect(scrub("https://e.com/orders/1048576")).to eq("/orders/:id")
    end

    # The leak this class exists to close: a small sequential id names an
    # individual just as surely as a seven-digit one. Publishing /player/51 into
    # the Top pages table enumerates the site's people, so the digit count must
    # not decide whether a numeric segment is treated as a record id.
    it "collapses a short numeric id the same as a long one" do
      expect(scrub("https://e.com/player/51")).to eq("/player/:id")
      expect(scrub("https://e.com/orders/5")).to eq("/orders/:id")
      expect(scrub("https://e.com/team/172/profile")).to eq("/team/:id/profile")
    end

    # A 16-char Crockford token (Site#public_token) and a 24-char base64 slug
    # (SharedLink#slug) both sit below the 25-char opaque threshold and are not
    # pure hex, so the earlier rules published them into Top pages verbatim.
    it "collapses a short high-entropy identifier that mixes letters and digits" do
      expect(scrub("https://e.com/sites/FB1WRC5D0PFFHKZ5")).to eq("/sites/:token")
      expect(scrub("https://e.com/sites/8TQTENJQQWHW8H40")).to eq("/sites/:token")
    end

    # Conservative on purpose: a page name written in camelCase carries no digit,
    # so it is left alone. The exact tool for a digitless id is a declared pattern.
    it "leaves a long digitless word segment alone" do
      expect(scrub("https://e.com/FrequentlyAskedQuestions")).to eq("/FrequentlyAskedQuestions")
    end

    it "decodes percent-encoding before deciding, so encoding cannot smuggle an email through" do
      expect(scrub("https://e.com/u/alice%40example.com")).to eq("/u/:email")
    end
  end

  describe "declared route patterns" do
    # The exact tool: the owner names the dynamic segment, so it collapses with no
    # guessing and no page name can be mistaken for an id.
    it "collapses a declared parameter to its name" do
      expect(scrub("https://e.com/player/51", patterns: ["/player/:id"])).to eq("/player/:id")
      expect(scrub("https://e.com/sites/FB1WRC5D0PFFHKZ5", patterns: ["/sites/:token"]))
        .to eq("/sites/:token")
    end

    it "collapses a low-entropy id that no heuristic could tell from a page name" do
      # /team/7 would otherwise be indistinguishable from a real page named "7".
      expect(scrub("https://e.com/team/7", patterns: ["/team/:id"])).to eq("/team/:id")
    end

    it "names a UUID segment after the pattern rather than the heuristic :uuid" do
      expect(scrub("https://e.com/goals/3f2504e0-4f89-41d3-9a0c-0305e82c3301",
                   patterns: ["/goals/:id"])).to eq("/goals/:id")
    end

    it "scrubs the undeclared tail with the heuristics" do
      expect(scrub("https://e.com/player/51/orders/1048576", patterns: ["/player/:id"]))
        .to eq("/player/:id/orders/:id")
    end

    it "leaves a path no pattern matches to the heuristics" do
      expect(scrub("https://e.com/docs/why-cookieless", patterns: ["/player/:id"]))
        .to eq("/docs/why-cookieless")
    end
  end

  describe "ordinary paths" do
    it "leaves a normal path alone" do
      expect(scrub("https://e.com/blog/why-cookieless-analytics")).to eq("/blog/why-cookieless-analytics")
    end

    # Date-organised URLs are extremely common and collapsing the year would
    # ruin the top-pages report for any publication that uses them.
    it "keeps a year segment" do
      expect(scrub("https://e.com/2026/roundup")).to eq("/2026/roundup")
      expect(scrub("https://e.com/blog/2025/07/hello")).to eq("/blog/2025/07/hello")
    end

    # The month and day survive only in the position that makes them a date: run
    # right after a year. This is what lets /player/51 collapse without taking
    # /2026/07/15 down with it.
    it "keeps the month and day that follow a year" do
      expect(scrub("https://e.com/2026/07/15/roundup")).to eq("/2026/07/15/roundup")
    end

    it "collapses a short number that is not in a date position" do
      # No preceding year, so 07 is a record id or a page number, not a month.
      expect(scrub("https://e.com/section/07/detail")).to eq("/section/:id/detail")
    end

    it "collapses a number after a year when it cannot be a real month or day" do
      expect(scrub("https://e.com/2026/99/roundup")).to eq("/2026/:id/roundup")
    end

    it "still collapses a long number that is not a plausible year" do
      expect(scrub("https://e.com/orders/98765")).to eq("/orders/:id")
      expect(scrub("https://e.com/p/3001")).to eq("/p/:id")
    end

    it "normalises the root" do
      expect(scrub("https://e.com")).to eq("/")
      expect(scrub("https://e.com/")).to eq("/")
    end

    it "strips a trailing slash so /pricing and /pricing/ are one page" do
      expect(scrub("https://e.com/pricing/")).to eq("/pricing")
    end

    it "caps the length" do
      # Many short segments, so nothing individually looks like a token and the
      # cap is what does the work.
      long = Array.new(120) { "seg" }.join("/")
      expect(scrub("https://e.com/#{long}").length).to eq(described_class::MAX_LENGTH)
    end

    it "collapses one absurdly long segment rather than truncating it" do
      # All-hex, so this is classified as a digest rather than a generic token.
      expect(scrub("https://e.com/#{'a' * 400}")).to eq("/:hash")
      # Mixed case takes it out of hex and into the opaque bucket.
      expect(scrub("https://e.com/#{'Xy9' * 40}")).to eq("/:token")
    end
  end

  describe "query parameters" do
    it "keeps utm parameters" do
      result = params("https://e.com/?utm_source=hn&utm_campaign=launch")
      expect(result[:utm_source]).to eq("hn")
      expect(result[:utm_campaign]).to eq("launch")
    end

    it "drops everything not allowlisted" do
      result = params("https://e.com/?sessionid=abc&email=a@b.com&utm_source=hn")
      expect(result.keys).to all(satisfy { |k| described_class::ALLOWED_PARAMS.include?(k.to_s) })
      expect(result.values.compact).to eq(["hn"])
    end

    it "drops a denied name even when it looks allowlisted" do
      expect(params("https://e.com/?token=secret")[:utm_source]).to be_nil
    end

    it "drops a utm value that looks like a token rather than a campaign name" do
      long = "a" * 40
      expect(params("https://e.com/?utm_source=#{long}")[:utm_source]).to be_nil
    end

    it "drops a utm value containing an email address" do
      expect(params("https://e.com/?utm_source=alice@example.com")[:utm_source]).to be_nil
    end
  end
end
