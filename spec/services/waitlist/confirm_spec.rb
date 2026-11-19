require "rails_helper"

RSpec.describe Waitlist::Confirm do
  describe "success" do
    it "records when permission was given" do
      signup = create(:waitlist_signup, token: "good-token")

      expect(described_class.call(token: "good-token")).to be_success
      expect(signup.reload).to be_confirmed
    end

    # Mail clients prefetch and people click twice. Re-stamping would make
    # confirmed_at say when the link was last opened rather than when consent
    # was actually given, which is the one thing this column is for.
    it "leaves the original timestamp alone on a second visit" do
      signup = create(:waitlist_signup, :confirmed, token: "good-token", confirmed_at: 3.days.ago)

      expect { described_class.call(token: "good-token") }
        .not_to(change { signup.reload.confirmed_at })
    end
  end

  describe "failure" do
    it "refuses a token nobody was issued" do
      expect(described_class.call(token: "never-issued")).to eq(Dry::Monads::Failure(:unknown_token))
    end

    it "refuses a blank token rather than confirming an arbitrary row" do
      create(:waitlist_signup)

      expect(described_class.call(token: nil)).to eq(Dry::Monads::Failure(:unknown_token))
      expect(WaitlistSignup.confirmed).to be_empty
    end
  end
end
