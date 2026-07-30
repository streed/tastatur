require "rails_helper"

RSpec.describe TwoFactor::TrustDevice do
  let(:user) { create(:user, :with_two_factor) }

  it "returns a token that finds the row, and stores only a digest" do
    credential = described_class.call(user: user).value!

    device = user.trusted_devices.sole
    expect(TrustedDevice.find_active(credential.token)).to eq(device)
    expect(device.token_digest).not_to eq(credential.token)
    expect(device.token_digest).to eq(TrustedDevice.digest_for(credential.token))
  end

  # The pair has to agree — a cookie that outlives its row challenges somebody
  # who was told it would not, and a row that outlives its cookie is trust that
  # can never be presented. See TwoFactor::DeviceCredential.
  it "reports the same expiry the row carries" do
    credential = described_class.call(user: user).value!

    expect(credential.expires_at).to be_within(5.seconds).of(TrustedDevice::TRUST_DURATION.from_now)
    expect(user.trusted_devices.sole.expires_at).to be_within(1.second).of(credential.expires_at)
  end

  it "issues a distinct token every time" do
    tokens = Array.new(3) { described_class.call(user: user).value!.token }

    expect(tokens.uniq.size).to eq(3)
  end

  it "clears out this user's expired rows as it goes" do
    stale = create(:trusted_device, :expired, user: user)
    someone_else = create(:trusted_device, :expired)

    described_class.call(user: user)

    expect(TrustedDevice.exists?(stale.id)).to be(false)
    expect(TrustedDevice.exists?(someone_else.id)).to be(true), "must only sweep its own user's rows"
  end

  it "caps the number of devices, dropping the oldest first" do
    oldest = create(:trusted_device, user: user, created_at: 2.years.ago)
    described_class::MAX_PER_USER.times { |n| create(:trusted_device, user: user, created_at: n.days.ago) }

    described_class.call(user: user)

    expect(user.trusted_devices.count).to eq(described_class::MAX_PER_USER)
    expect(TrustedDevice.exists?(oldest.id)).to be(false)
  end

  # The cap must never cost somebody the device they are creating right now,
  # which is what a naive "delete the oldest, then insert" would do at the
  # boundary.
  it "keeps the device it just issued even at the cap" do
    described_class::MAX_PER_USER.times { create(:trusted_device, user: user, created_at: 1.hour.ago) }

    credential = described_class.call(user: user).value!

    expect(TrustedDevice.find_active(credential.token)).to be_present
  end
end
