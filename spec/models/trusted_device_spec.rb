require "rails_helper"

RSpec.describe TrustedDevice do
  describe ".digest_for" do
    it "is deterministic, so a cookie can be looked up rather than scanned for" do
      expect(described_class.digest_for("abc")).to eq(described_class.digest_for("abc"))
      expect(described_class.digest_for("abc")).not_to eq(described_class.digest_for("abd"))
    end

    it "does not contain the token it came from" do
      expect(described_class.digest_for("abc")).not_to include("abc")
    end
  end

  describe ".new_token" do
    it "is long and unpredictable, which is why a fast hash is enough" do
      tokens = Array.new(50) { described_class.new_token }

      expect(tokens.uniq.size).to eq(50)
      expect(tokens.first.length).to be >= 40
    end
  end

  describe ".find_active" do
    let(:user) { create(:user) }

    it "finds a live device by its raw token" do
      token = described_class.new_token
      device = create(:trusted_device, user: user, token: token)

      expect(described_class.find_active(token)).to eq(device)
    end

    it "does not find an expired one" do
      token = described_class.new_token
      create(:trusted_device, :expired, user: user, token: token)

      expect(described_class.find_active(token)).to be_nil
    end

    it "does not find one from a token that was never issued" do
      create(:trusted_device, user: user)

      expect(described_class.find_active(described_class.new_token)).to be_nil
    end

    # A blank token must not digest to something a row could hold. Impossible
    # today, and exactly the kind of thing that stops being true later.
    it "answers nil for a blank token rather than hashing the empty string" do
      expect(described_class.find_active(nil)).to be_nil
      expect(described_class.find_active("")).to be_nil
    end
  end

  it "is routed by public_id, never by its primary key" do
    device = create(:trusted_device)

    expect(device.to_param).to eq(device.public_id)
    expect(device.to_param).not_to eq(device.id.to_s)
  end

  it "goes when its user does" do
    user = create(:user)
    create(:trusted_device, user: user)

    expect { user.destroy }.to change { described_class.count }.by(-1)
  end

  describe "#record_use!" do
    it "stamps last_used_at without touching updated_at" do
      device = create(:trusted_device, last_used_at: 10.days.ago, updated_at: 10.days.ago)

      device.record_use!

      expect(device.reload.last_used_at).to be_within(5.seconds).of(Time.current)
      expect(device.updated_at).to be_within(1.minute).of(10.days.ago)
    end
  end

  describe "User#visible_trusted_devices" do
    it "is empty when two-factor is off, whatever rows exist" do
      user = create(:user)
      create(:trusted_device, user: user)

      expect(user.visible_trusted_devices).to be_empty
    end

    it "lists live devices newest first" do
      user = create(:user, :with_two_factor)
      older = create(:trusted_device, user: user, created_at: 2.days.ago)
      newer = create(:trusted_device, user: user, created_at: 1.hour.ago)
      create(:trusted_device, :expired, user: user)

      expect(user.visible_trusted_devices.to_a).to eq([newer, older])
    end
  end
end
