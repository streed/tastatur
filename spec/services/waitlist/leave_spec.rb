require "rails_helper"

RSpec.describe Waitlist::Leave do
  describe "success" do
    # THE POINT OF THE WHOLE SERVICE. The industry default is a suppression
    # list: keep the row, set a flag. That makes the answer to "stop holding my
    # address" a row holding their address, kept because they asked us not to
    # have it. This spec is what stops that being reintroduced as an
    # optimisation.
    it "deletes the row rather than flagging it" do
      create(:waitlist_signup, :confirmed, token: "leave-me")

      expect { described_class.call(token: "leave-me") }.to change(WaitlistSignup, :count).by(-1)
    end

    it "works before confirmation as well as after" do
      create(:waitlist_signup, token: "leave-me")

      expect(described_class.call(token: "leave-me")).to eq(Dry::Monads::Success(:removed))
    end

    it "leaves nothing behind for the address to be matched against later" do
      create(:waitlist_signup, :confirmed, email: "gone@example.com", token: "leave-me")

      described_class.call(token: "leave-me")

      expect(WaitlistSignup.where(email: "gone@example.com")).to be_empty
    end
  end

  describe "failure" do
    it "refuses an unknown token" do
      expect(described_class.call(token: "never-issued")).to eq(Dry::Monads::Failure(:unknown_token))
    end

    it "refuses a blank token rather than deleting an arbitrary row" do
      create(:waitlist_signup)

      expect { described_class.call(token: "") }.not_to change(WaitlistSignup, :count)
    end
  end
end
