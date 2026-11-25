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
    key = ApiKey.generate!(site: site, name: "agent", scopes: ["read:analytics"])
    expect(key.allows?("read:analytics")).to be(true)
    expect(key.allows?("write:identify")).to be(false)
  end

  describe "ownership of an agent key" do
    let(:maker) { create(:user) }

    it "requires an owner for a key that reads" do
      key = ApiKey.generate!(site: site, name: "agent", scopes: ["read:analytics"])
      expect(key).not_to be_valid
      expect(key.errors[:user]).to be_present
    end

    it "does not require one for an identify key" do
      expect(ApiKey.generate!(site: site, name: "server")).to be_valid
    end

    it "is honoured only while the owner belongs to the account" do
      membership = create(:membership, account: site.account, user: maker, role: "viewer")
      key = ApiKey.generate!(site: site, name: "agent", scopes: ["read:analytics"], user: maker).tap(&:save!)

      expect(ApiKey.authenticate(key.plaintext)).to eq(key)

      membership.destroy
      expect(ApiKey.authenticate(key.plaintext)).to be_nil
    end

    it "is deleted with its owner rather than freed from them" do
      create(:membership, account: site.account, user: maker, role: "viewer")
      ApiKey.generate!(site: site, name: "agent", scopes: ["read:analytics"], user: maker).save!

      expect { maker.destroy }.to change(ApiKey, :count).by(-1)
    end
  end

  describe "key names" do
    let(:one) { create(:user) }
    let(:two) { create(:user) }

    def agent_key(name, user) = ApiKey.generate!(site: site, name: name, scopes: ["read:analytics"], user: user)

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

    it "is enforced by the database too, including for unowned keys" do
      ApiKey.generate!(site: site, name: "production").save!

      expect { ApiKey.generate!(site: site, name: "production").save!(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
