require "rails_helper"

# The confirmation email tells the recipient an unconfirmed address is deleted
# within a week. That makes this a promise in writing rather than housekeeping,
# which is why it has a spec and a named cron entry.
RSpec.describe Waitlist::PurgeUnconfirmed do
  it "deletes an address that was never confirmed" do
    create(:waitlist_signup, :stale)

    expect { described_class.call }.to change(WaitlistSignup, :count).by(-1)
  end

  it "reports how many it removed" do
    create_list(:waitlist_signup, 2, :stale)

    expect(described_class.call).to eq(Dry::Monads::Success(2))
  end

  it "keeps one that is still inside the window" do
    create(:waitlist_signup, created_at: 1.day.ago)

    expect { described_class.call }.not_to change(WaitlistSignup, :count)
  end

  # A member is a member however long ago they joined. Sweeping confirmed rows
  # would quietly empty the list this whole feature exists to hold.
  it "never touches a confirmed address, however old" do
    create(:waitlist_signup, :confirmed, created_at: 2.years.ago)

    expect { described_class.call }.not_to change(WaitlistSignup, :count)
  end
end
