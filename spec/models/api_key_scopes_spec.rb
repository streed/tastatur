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
end
