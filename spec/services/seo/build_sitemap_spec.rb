require "rails_helper"

RSpec.describe Seo::BuildSitemap do
  subject(:entries) { described_class.call(url_options: url_options).value! }

  let(:url_options) { { protocol: "https://", host: "analytics.example.org" } }

  def locs = entries.map(&:loc)

  before { allow(Tastatur).to receive(:billing_enabled?).and_return(true) }

  # Pinned as a set rather than spot-checked, so adding a page to the sitemap is
  # an edit somebody makes on purpose. The class comment explains why a derived
  # list would be a disclosure rather than a convenience.
  it "lists exactly the public content pages" do
    expect(locs).to contain_exactly(
      "https://analytics.example.org/",
      "https://analytics.example.org/docs",
      "https://analytics.example.org/about",
      "https://analytics.example.org/pricing",
      "https://analytics.example.org/privacy",
      "https://analytics.example.org/privacy-policy",
      "https://analytics.example.org/terms",
      "https://analytics.example.org/dpa",
      "https://analytics.example.org/data-request"
    )
  end

  # Every URL is absolute on the host that was asked for, never a compiled-in
  # one. A self-hosted install publishes its own domain; the alternative is
  # every copy of Tastatur advertising tastatur.dev's pages as its own.
  it "builds absolute URLs on the host it was given" do
    expect(locs).to all(start_with("https://analytics.example.org/"))
  end

  describe "the pricing page" do
    it "is listed where there is something to buy" do
      expect(locs).to include("https://analytics.example.org/pricing")
    end

    # PricingController redirects to the root wherever billing is off, and a
    # sitemap entry that redirects is reported back as an error rather than
    # followed. Same condition, and the same reasoning, as llms.txt.
    it "is omitted where there is not, rather than pointing a crawler at a bounce" do
      allow(Tastatur).to receive(:billing_enabled?).and_return(false)

      expect(locs).not_to include(a_string_including("/pricing"))
    end
  end

  describe "lastmod" do
    it "is set on the two documents that print a revision date, and only those" do
      allow(Tastatur).to receive(:legal).and_return({ updated_on: Date.new(2026, 2, 11) })

      dated = entries.select(&:lastmod)

      expect(dated.map(&:loc)).to contain_exactly(
        "https://analytics.example.org/privacy-policy",
        "https://analytics.example.org/terms"
      )
      expect(dated.map(&:lastmod).uniq).to eq([Date.new(2026, 2, 11)])
    end

    # The failure mode this avoids is not an empty field, it is a confident
    # wrong one: a sitemap whose every entry claims to have changed today is
    # why crawlers stop reading the field for that host at all.
    it "is omitted entirely when no revision date is configured, never invented" do
      allow(Tastatur).to receive(:legal).and_return({ updated_on: nil })

      expect(entries.map(&:lastmod).compact).to be_empty
    end
  end

  # The list is a constant, not a query. Nothing a customer creates can reach
  # it, which is the property spec/requests/sitemap_spec.rb then asserts on the
  # rendered file.
  it "does not grow with the database" do
    expect { create(:shared_link, site: create(:site)) }
      .not_to change { described_class.call(url_options: url_options).value!.size }
  end
end
