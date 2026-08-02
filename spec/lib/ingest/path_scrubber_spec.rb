require "rails_helper"

RSpec.describe Ingest::PathScrubber do
  def scrub(url) = described_class.call(URI.parse(url))
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

    it "decodes percent-encoding before deciding, so encoding cannot smuggle an email through" do
      expect(scrub("https://e.com/u/alice%40example.com")).to eq("/u/:email")
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
