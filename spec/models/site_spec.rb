require "rails_helper"

# The plan's site limit, and which hostnames a site may claim. Normalisation's own
# rules and the policy that consumes these hostnames are covered in
# spec/lib/ingest/hostname_policy_spec.rb and the request specs, and duplicating
# them here would mean two files to update for one change.
RSpec.describe Site do
  # The uniqueness validation is only worth as much as the normalisation that
  # runs before it. Both halves are load-bearing and neither is obvious from
  # reading one of them: `before_validation :normalize_domain` is what makes
  # "https://WWW.Example.com/" and "example.com" the same row, and dropping it
  # to a plain string comparison would let every one of these through.
  describe "adding the same domain twice" do
    let(:account) { create(:account, plan: "pro") }

    before { account.sites.create!(domain: "example.com") }

    it "refuses an exact repeat" do
      duplicate = build(:site, account: account, domain: "example.com")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:domain]).to include("has already been taken")
    end

    # Everything a person actually pastes out of a browser's address bar.
    [
      "https://example.com",
      "http://example.com/",
      "WWW.Example.COM",
      "https://WWW.Example.com/pricing?ref=x",
      "example.com:3000",
      "example.com."
    ].each do |pasted|
      it "refuses #{pasted.inspect}, which normalises to the same host" do
        expect(build(:site, account: account, domain: pasted)).not_to be_valid
      end
    end

    # Scoped to the account ON PURPOSE, and this is the assertion that says so.
    # An agency and its client both legitimately measure the same host, and a
    # global constraint would let anyone squat a domain they do not own and
    # permanently block its owner from onboarding.
    it "allows a different account to measure the same domain" do
      other = create(:account, plan: "pro")

      expect(other.sites.build(domain: "example.com")).to be_valid
    end

    # The validation reads; this is what enforces. A spec on the validation alone
    # would still pass with the index dropped, and the race in SitesController
    # would then insert the duplicate instead of being caught.
    it "is enforced by the database even when the validation is bypassed" do
      # `validate: false` skips before_validation too, so the token that
      # assign_public_token would have minted has to be supplied by hand.
      duplicate = build(:site, account: account, domain: "example.com", public_token: "0123456789ABCDEF")

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "the account's site limit" do
    it "allows the first site on a free account and refuses the second" do
      account = create(:account, plan: "free")
      expect(create(:site, account: account)).to be_persisted

      second = build(:site, account: account)

      expect(second).not_to be_valid
      expect(second.errors[:base].first).to include("limited to 1 site")
      expect(second.errors[:base].first).to include("Upgrade to Pro for 20 sites")
    end

    it "allows twenty on a paid account and refuses the twenty-first" do
      account = create(:account, plan: "pro")
      20.times { |i| account.sites.create!(domain: "site-#{i}.example.com") }

      expect(build(:site, account: account)).not_to be_valid
    end

    # The message has to name the way out, and on the largest plan that is not
    # "upgrade" — an account already on Pro is told to delete one or ask, because
    # offering an upgrade that does not exist wastes their time.
    it "does not offer an upgrade to an account already on the largest plan" do
      account = create(:account, plan: "pro", site_limit_override: 1)
      create(:site, account: account)

      second = build(:site, account: account)
      second.valid?

      expect(second.errors[:base].first).to include("Delete a site you no longer measure")
      expect(second.errors[:base].first).not_to include("Upgrade")
    end

    it "respects an override" do
      account = create(:account, plan: "free", site_limit_override: 3)

      expect { 3.times { |i| account.sites.create!(domain: "over-#{i}.example.com") } }.not_to raise_error
      expect(build(:site, account: account)).not_to be_valid
    end

    it "does not apply at all on a self-hosted install" do
      allow(Tastatur).to receive(:self_hosted?).and_return(true)
      account = create(:account, plan: "free")

      expect { 5.times { |i| account.sites.create!(domain: "self-#{i}.example.com") } }.not_to raise_error
    end

    # THE REASON THE VALIDATION IS `on: :create`.
    #
    # An account that cancels Pro drops to Free holding twenty sites, because a
    # billing event must not delete customer data. An unscoped validation would
    # then refuse every save on every one of those sites — changing a timezone
    # would fail with a message about site limits, and the only way out would be
    # deleting nineteen sites. So the limit governs adding, never keeping.
    describe "an account left over its limit by a downgrade" do
      let(:account) { create(:account, plan: "free", site_limit_override: 4) }
      let!(:sites) { Array.new(4) { |i| account.sites.create!(domain: "kept-#{i}.example.com") } }

      before { account.update!(site_limit_override: nil) }

      it "can still edit its existing sites" do
        expect(sites.first.update(timezone: "Europe/Berlin")).to be(true)
        expect(sites.first.update(k_anonymity_threshold: 0)).to be(true)
        expect(sites.last.update(extra_hostnames_list: "app.kept-3.example.com")).to be(true)
      end

      it "can still delete one" do
        expect { Sites::Delete.call(site: sites.first) }.to change(Site, :count).by(-1)
      end

      it "still cannot add another" do
        expect(build(:site, account: account)).not_to be_valid
      end
    end
  end

  # `extra_hostnames` feeds Ingest::HostnamePolicy#candidates alongside `domain`
  # and is treated identically there, but until now only `domain` was validated.
  describe "additional hostnames" do
    let(:account) { create(:account, plan: "pro") }
    let(:site) { create(:site, account: account, domain: "example.com") }

    it "accepts a genuinely separate domain, which is what the field is for" do
      expect(site.update(extra_hostnames_list: "example.de\nexample.co.jp")).to be(true)
      expect(site.reload.extra_hostnames).to eq(%w[example.de example.co.jp])
    end

    it "normalises each entry the same way the domain is normalised" do
      expect(site.update(extra_hostnames_list: "https://WWW.Example.DE/pricing\n example.fr:8080 ")).to be(true)
      expect(site.reload.extra_hostnames).to eq(%w[example.de example.fr])
    end

    it "refuses an entry that is not a hostname and names the offender" do
      expect(site.update(extra_hostnames_list: "example.de\nnot-a-hostname")).to be(false)
      expect(site.errors[:extra_hostnames_list].first).to include("must each be a bare hostname")
      expect(site.errors[:extra_hostnames_list].first).to include("not-a-hostname")
    end

    # THE ONE WITH A SECURITY CONSEQUENCE. `permitted?` accepts anything ending in
    # ".#{allowed}", so a bare suffix here accepts every hostname beneath it while
    # the settings page still reports enforcement as on. `github.io` is the version
    # somebody actually types, because that is where their site lives.
    %w[co.uk github.io vercel.app].each do |suffix|
      it "refuses #{suffix}, which would accept every hostname beneath it" do
        expect(site.update(extra_hostnames_list: suffix)).to be(false)
        expect(site.errors[:extra_hostnames_list].first).to include("public suffix")
      end
    end

    it "refuses a public suffix as the domain too, since both feed the same policy" do
      bad = build(:site, account: account, domain: "co.uk")

      expect(bad).not_to be_valid
      expect(bad.errors[:domain].first).to include("public suffix")
    end

    # Only a BARE suffix. The registrable name under one is an ordinary site and
    # a rule that refused it would be unusable by everyone on GitHub Pages.
    it "accepts a real site hosted under a public suffix" do
      expect(build(:site, account: account, domain: "mysite.github.io")).to be_valid
      expect(site.update(extra_hostnames_list: "docs.mysite.github.io")).to be(true)
    end
  end

  # NOT because it double-counts. Ingest::SiteResolver resolves the site from the
  # token in the snippet, so each site receives only what its own snippet sends.
  # The cost is the signal: an overlap makes the wrong snippet acceptable to both
  # sites, so pasting site A's key onto site B's page stops being refused and stops
  # appearing in Site#rejected_hostnames — the one place that mistake is visible.
  describe "a hostname another site in the account already claims" do
    let(:account) { create(:account, plan: "pro") }
    let!(:existing) { account.sites.create!(domain: "example.com") }

    it "refuses it as an additional hostname on a second site" do
      other = account.sites.create!(domain: "shop.example.net")

      expect(other.update(extra_hostnames_list: "example.com")).to be(false)
      expect(other.errors[:extra_hostnames_list].first)
        .to include("already the domain of another site in this account")
    end

    # Symmetrical, and checked from both ends: whichever field the person is
    # editing has to be the one that refuses, or the message names a remedy on a
    # page they are not looking at.
    it "refuses it as the domain of a new site when a sibling lists it as extra" do
      existing.update!(extra_hostnames_list: "example.de")

      expect(build(:site, account: account, domain: "example.de")).not_to be_valid
    end

    it "refuses the same additional hostname on two sites" do
      first = account.sites.create!(domain: "one.example.net")
      first.update!(extra_hostnames_list: "shared.example.org")
      second = account.sites.create!(domain: "two.example.net")

      expect(second.update(extra_hostnames_list: "shared.example.org")).to be(false)
    end

    # Same reasoning as domain uniqueness being account-scoped: two unrelated
    # customers measuring the same host is legitimate and not ours to arbitrate.
    it "allows another account to claim the same hostname" do
      other = create(:account, plan: "pro").sites.create!(domain: "unrelated.example.net")

      expect(other.update(extra_hostnames_list: "example.com")).to be(true)
    end

    it "does not count the site's own domain as a conflict with itself" do
      expect(existing.update(extra_hostnames_list: "example.de")).to be(true)
    end
  end

  # THE REASON ALL THREE ARE GATED ON THE HOSTNAME CHANGING, and the same reason
  # `account_within_site_limit` is `on: :create`. These validations postdate the
  # rows they apply to, and `extra_hostnames_list=` never checked its input, so
  # values exist that they would refuse. Applied unconditionally, a site holding
  # one would be unable to save an unrelated field — and for the overlap check the
  # refusal appears on the site you are NOT editing, so the remedy would live on a
  # different page than the error.
  describe "a site already holding a value the new rules refuse" do
    let(:account) { create(:account, plan: "pro") }
    let!(:site) do
      create(:site, account: account, domain: "example.com").tap do |s|
        s.update_columns(extra_hostnames: ["co.uk", "not a hostname"])
      end
    end

    it "can still save an unrelated field" do
      expect(site.update(timezone: "Europe/Berlin")).to be(true)
      expect(site.update(k_anonymity_threshold: 0)).to be(true)
    end

    it "still refuses the moment that field is touched" do
      expect(site.update(extra_hostnames_list: "co.uk")).to be(false)
    end

    it "accepts the correction" do
      expect(site.update(extra_hostnames_list: "example.co.uk")).to be(true)
    end
  end

  # The route patterns that let Ingest::PathScrubber collapse a site's dynamic
  # segments exactly. Normalisation makes the stored form line up with how a real
  # path is matched, and the validation keeps a malformed pattern — which would
  # silently never match — out of the column.
  describe "route patterns" do
    let(:site) { create(:site) }

    it "stores one pattern per line with a leading slash and no trailing slash" do
      site.update!(path_patterns_list: "sites/:token\n/player/:id/\n\n  /blog/:year  ")
      expect(site.path_patterns).to eq(["/sites/:token", "/player/:id", "/blog/:year"])
    end

    it "drops duplicates" do
      site.update!(path_patterns_list: "/player/:id\n/player/:id")
      expect(site.path_patterns).to eq(["/player/:id"])
    end

    it "accepts literal and named-parameter segments" do
      expect(site.update(path_patterns_list: "/sites/:token/edit")).to be(true)
    end

    it "refuses a segment that is neither a literal nor a :name parameter" do
      expect(site.update(path_patterns_list: "/sites/:")).to be(false)
      expect(site.errors[:path_patterns]).to be_present
    end

    it "refuses more than the maximum number of patterns" do
      many = Array.new(Site::MAX_PATH_PATTERNS + 1) { |i| "/p#{i}/:id" }.join("\n")
      expect(site.update(path_patterns_list: many)).to be(false)
      expect(site.errors[:path_patterns]).to be_present
    end
  end
end
