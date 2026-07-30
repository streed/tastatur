require "rails_helper"

RSpec.describe TwoFactor::Enable do
  it "switches it on" do
    user = create(:user)

    expect(described_class.call(user: user)).to eq(Dry::Monads::Success(user))
    expect(user.reload.two_factor_enabled?).to be(true)
  end

  it "refuses when it is already on" do
    user = create(:user, :with_two_factor)

    expect(described_class.call(user: user)).to eq(Dry::Monads::Failure(:already_enabled))
  end

  # The guard that keeps TwoFactor::Enable's "no enrolment challenge needed"
  # argument true. It rests entirely on confirmation having proved the mailbox
  # receives mail; without this check, an unconfirmed address could be locked
  # behind codes it will never receive.
  it "refuses an unconfirmed address, so codes cannot be sent somewhere unproven" do
    user = create(:user, :unconfirmed)

    expect(described_class.call(user: user)).to eq(Dry::Monads::Failure(:unconfirmed))
    expect(user.reload.two_factor_enabled?).to be(false)
  end

  it "does not touch trusted devices, which only a challenge can create" do
    user = create(:user)

    described_class.call(user: user)

    expect(user.trusted_devices).to be_empty
  end
end
