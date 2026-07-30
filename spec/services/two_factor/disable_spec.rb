require "rails_helper"

RSpec.describe TwoFactor::Disable do
  let(:user) { create(:user, :with_two_factor) }

  it "switches it off" do
    expect(described_class.call(user: user)).to eq(Dry::Monads::Success(user))
    expect(user.reload.two_factor_enabled?).to be(false)
  end

  it "refuses when it is already off" do
    plain = create(:user)

    expect(described_class.call(user: plain)).to eq(Dry::Monads::Failure(:already_disabled))
  end

  # THE PROPERTY THIS SERVICE EXISTS FOR. Clearing the flag alone leaves rows
  # that come back to life the moment two-factor is switched on again — devices
  # the person may no longer own, silently skipping the challenge they just
  # asked for.
  it "forgets every trusted device, so switching it back on starts from nothing" do
    create_list(:trusted_device, 3, user: user)
    someone_else = create(:trusted_device)

    described_class.call(user: user)

    expect(user.trusted_devices.reload).to be_empty
    expect(TrustedDevice.exists?(someone_else.id)).to be(true)
  end

  it "discards any outstanding code" do
    user.update!(
      two_factor_code: "123456",
      two_factor_code_sent_at: Time.current,
      two_factor_code_expires_at: 5.minutes.from_now,
      two_factor_failed_attempts: 3
    )

    described_class.call(user: user)

    user.reload
    expect(user.two_factor_code_digest).to be_nil
    expect(user.two_factor_code_expires_at).to be_nil
    expect(user.two_factor_failed_attempts).to eq(0)
  end
end
