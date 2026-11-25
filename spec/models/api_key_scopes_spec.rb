require "rails_helper"

RSpec.describe ApiKey, "scopes" do
  let(:site) { create(:site) }

  it "defaults to the identify scope, which is what every key could do before scopes existed" do
    expect(ApiKey.generate!(site: site, name: "old").scopes).to eq(["write:identify"])
  end

  it "rejects an unknown scope" do
    key = ApiKey.generate!(site: site, name: "x", scopes: ["admin"])
    expect(key).not_to be_valid
  end

  it "rejects no scopes at all" do
    expect(ApiKey.generate!(site: site, name: "x", scopes: [])).not_to be_valid
  end

  it "grants only what it was created with" do
    key = ApiKey.generate!(account: site.account, name: "agent", scopes: ["read:analytics"], user: create(:user))
    expect(key.allows?("read:analytics")).to be(true)
    expect(key.allows?("write:identify")).to be(false)
  end

  describe "ownership of an agent key" do
    let(:maker) { create(:user) }

    it "requires an owner for a key that reads" do
      key = ApiKey.generate!(account: site.account, name: "agent", scopes: ["read:analytics"])
      expect(key).not_to be_valid
      expect(key.errors[:user]).to be_present
    end

    it "does not require one for an identify key" do
      expect(ApiKey.generate!(site: site, name: "server")).to be_valid
    end

    it "is honoured only while the owner belongs to the account" do
      membership = create(:membership, account: site.account, user: maker, role: "viewer")
      key = ApiKey.generate!(account: site.account, name: "agent", scopes: ["read:analytics"], user: maker).tap(&:save!)

      expect(ApiKey.authenticate(key.plaintext)).to eq(key)

      membership.destroy
      expect(ApiKey.authenticate(key.plaintext)).to be_nil
    end

    it "is deleted with its owner rather than freed from them" do
      create(:membership, account: site.account, user: maker, role: "viewer")
      ApiKey.generate!(account: site.account, name: "agent", scopes: ["read:analytics"], user: maker).save!

      expect { maker.destroy }.to change(ApiKey, :count).by(-1)
    end
  end

  describe "what a key belongs to" do
    it "puts an agent key on the account and an identify key on a site, never the other way round" do
      expect(ApiKey.generate!(site: site, name: "a", scopes: ["read:analytics"], user: create(:user))).not_to be_valid
      expect(ApiKey.generate!(account: site.account, name: "b", user: create(:user))).not_to be_valid
    end

    it "is refused by the database too if it has both, or neither" do
      both = ApiKey.generate!(site: site, account: site.account, name: "x", user: create(:user))
      neither = ApiKey.generate!(name: "y")

      expect { both.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
      expect { neither.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "reaches every site in its account through the account, not through a site" do
      key = ApiKey.generate!(account: site.account, name: "agent", scopes: ["read:analytics"], user: create(:user))

      expect(key.site).to be_nil
      expect(key.owning_account_id).to eq(site.account_id)
    end
  end

  describe "key names" do
    let(:one) { create(:user) }
    let(:two) { create(:user) }

    def agent_key(name, user) = ApiKey.generate!(account: site.account, name: name, scopes: ["read:analytics"], user: user)

    it "may be reused by different people on the same site" do
      agent_key("claude", one).save!

      expect(agent_key("claude", two)).to be_valid
    end

    it "may not be reused by the same person" do
      agent_key("claude", one).save!

      expect(agent_key("claude", one)).not_to be_valid
    end

    it "is still unique per site for identify keys, which have no owner" do
      ApiKey.generate!(site: site, name: "production").save!

      expect(ApiKey.generate!(site: site, name: "production")).not_to be_valid
    end

    it "is enforced by the database too, for both kinds" do
      ApiKey.generate!(site: site, name: "production").save!
      expect { ApiKey.generate!(site: site, name: "production").save!(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)

      agent_key("claude", one).save!
      expect { agent_key("claude", one).save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "may repeat across accounts for the same person" do
      other = create(:site)
      agent_key("claude", one).save!

      expect(ApiKey.generate!(account: other.account, name: "claude", scopes: ["read:analytics"], user: one)).to be_valid
    end
  end
end
