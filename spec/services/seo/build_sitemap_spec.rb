require "rails_helper"

RSpec.describe Seo::BuildSitemap do
  subject(:entries) { described_class.call(url_options: url_options).value! }

  let(:url_options) { { protocol: "https://", host: "analytics.example.org" } }

  def locs = entries.map(&:loc)

  before { allow(Tastatur).to receive(:billing_enabled?).and_return(true) }

  # Pinned as a set rather than spot-checked, so adding a page to the sitemap is
  # an edit somebody makes on purpose. The class comment explains why a derived
  # list would be a disclosure rather than a convenience.
  #
  # The registry is emptied first so this stays an assertion about THIS
  # repository's list even when an edition is checked out and has added its own.
  # Without that, the example would assert something different depending on what
  # happens to be on disk, and would fail on the hosted deployment for the one
  # reason that is not a bug.
  it "lists exactly the public content pages" do
    allow(described_class).to receive(:registrations).and_return({})

    expect(locs).to contain_exactly(
      "https://analytics.example.org/docs",
      "https://analytics.example.org/privacy",
      "https://analytics.example.org/privacy-policy",
      "https://analytics.example.org/terms",
      "https://analytics.example.org/dpa"
    )
  end

  # THE ROOT PATH IS NOT ONE OF THEM, and the omission is the point. Without an
  # edition `/` is the sign-in form (PagesController#home), which is not written
  # to be read by anyone and declares no metadata for a crawler — and the entry
  # would be a redirect, which every search console reports back as an error
  # rather than following. A deployment that serves a landing page there
  # registers it, and that registration is asserted where it lives.
  it "does not list the root path, because a sign-in form is not public content" do
    allow(described_class).to receive(:registrations).and_return({})

    expect(locs).not_to include("https://analytics.example.org/")
  end

  # Every URL is absolute on the host that was asked for, never a compiled-in
  # one. A self-hosted install publishes its own domain; the alternative is
  # every copy of Tastatur advertising tastatur.dev's pages as its own.
  it "builds absolute URLs on the host it was given" do
    expect(locs).to all(start_with("https://analytics.example.org/"))
  end

  # The pricing and FAQ entries are registered by an edition and asserted in the
  # repository that registers them. What belongs here is that the registry
  # exists, is used, and cannot silently double up — below.
  describe "edition registrations" do
    after { described_class.registrations.delete(:test_edition) }

    it "includes what an edition registers" do
      described_class.register(:test_edition) do |opts|
        [ Seo::SitemapEntry.new(loc: "#{opts[:protocol]}#{opts[:host]}/registered") ]
      end

      expect(locs).to include("https://analytics.example.org/registered")
    end

    # Keyed rather than appended, because config.to_prepare re-registers on
    # every reload in development. An appended registry would list every edition
    # page once per reload and the sitemap would grow all afternoon.
    it "replaces a registration rather than listing the page twice" do
      2.times do
        described_class.register(:test_edition) do |opts|
          [ Seo::SitemapEntry.new(loc: "#{opts[:protocol]}#{opts[:host]}/registered") ]
        end
      end

      expect(locs.count("https://analytics.example.org/registered")).to eq(1)
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
