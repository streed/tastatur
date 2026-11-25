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
end
