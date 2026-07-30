require "rails_helper"

# Only the plan's site limit. Domain normalisation and hostname policy have their
# own coverage (spec/lib/ingest/hostname_policy_spec.rb and the request specs),
# and duplicating it here would mean two files to update for one change.
RSpec.describe Site do
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
end
