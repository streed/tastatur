require "rails_helper"

RSpec.describe WaitlistSignup do
  describe "the address" do
    it "is stored lowercase and trimmed, so one mailbox is one row" do
      signup = create(:waitlist_signup, email: "  Person@Example.COM  ")

      expect(signup.email).to eq("person@example.com")
    end

    # The normalisation has to apply to the lookup as well as the write, or a
    # resend goes looking for a row that is there and hits the unique index
    # instead of finding it.
    it "is found by a differently-cased lookup" do
      create(:waitlist_signup, email: "person@example.com")

      expect(described_class.find_by(email: "PERSON@example.com")).to be_present
    end

    it "is unique per feature" do
      create(:waitlist_signup, email: "person@example.com")
      duplicate = build(:waitlist_signup, email: "person@example.com")

      expect(duplicate).not_to be_valid
    end

    it "is refused when it is not an address" do
      expect(build(:waitlist_signup, email: "not-an-address")).not_to be_valid
    end
  end

  describe "the feature" do
    it "must be one the catalogue names" do
      expect(build(:waitlist_signup, feature: "teleportation")).not_to be_valid
    end

    # The Ruby list and the CHECK constraint are two statements of one rule, and
    # the failure mode of them disagreeing is a row the application refuses to
    # write and the database happily holds.
    it "is pinned in the database as well as in the model" do
      constraint = ActiveRecord::Base.connection
                                     .check_constraints("waitlist_signups")
                                     .find { |c| c.name == "waitlist_signups_feature_check" }

      expect(constraint).to be_present
      described_class::FEATURES.each { |feature| expect(constraint.expression).to include(feature) }
    end
  end

  describe "the token" do
    it "is found by presenting it" do
      signup = create(:waitlist_signup, token: "a-known-token")

      expect(described_class.find_by_token("a-known-token")).to eq(signup)
    end

    it "is not found by presenting nothing" do
      create(:waitlist_signup)

      expect(described_class.find_by_token(nil)).to be_nil
      expect(described_class.find_by_token("")).to be_nil
    end
  end

  describe "the resend cooldown" do
    it "allows a first send" do
      expect(build(:waitlist_signup, confirmation_sent_at: nil)).to be_resend_allowed
    end

    it "refuses one inside the interval" do
      expect(build(:waitlist_signup, confirmation_sent_at: 1.minute.ago)).not_to be_resend_allowed
    end

    it "allows one after it" do
      signup = build(:waitlist_signup, confirmation_sent_at: described_class::RESEND_INTERVAL.ago - 1.second)

      expect(signup).to be_resend_allowed
    end
  end

  describe "scopes" do
    it "separates members from claims" do
      confirmed = create(:waitlist_signup, :confirmed)
      pending = create(:waitlist_signup)

      expect(described_class.confirmed).to eq([confirmed])
      expect(described_class.pending).to eq([pending])
    end
  end
end
