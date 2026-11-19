require "rails_helper"

RSpec.describe Waitlist::Join do
  # The mail is enqueued rather than delivered, so every assertion about what was
  # sent has to run the queue. Same shape as IssueChallenge's spec.
  def join(email:, source: "revenue_page", **extra)
    perform_enqueued_jobs { described_class.call(params: { email: email, source: source, **extra }) }
  end

  # The token is only ever readable from the message. Reading it from there
  # rather than from the database is what proves the column holds a digest.
  def emailed_token
    ActionMailer::Base.deliveries.last&.body.to_s[%r{waitlist/confirm/([\w\-]+)}, 1]
  end

  before { ActionMailer::Base.deliveries.clear }

  describe "a new address" do
    it "stores it unconfirmed and mails a link" do
      expect { join(email: "new@example.com") }
        .to change(WaitlistSignup, :count).by(1)
        .and change { ActionMailer::Base.deliveries.size }.by(1)

      signup = WaitlistSignup.sole
      expect(signup).not_to be_confirmed
      expect(signup.source).to eq("revenue_page")
    end

    it "reports success" do
      expect(join(email: "new@example.com")).to eq(Dry::Monads::Success(:sent))
    end

    # The token is what proves possession of the mailbox, so a stored copy would
    # make the database a set of working confirmation links.
    it "stores a digest and never the token itself" do
      join(email: "new@example.com")

      token = emailed_token
      signup = WaitlistSignup.sole

      expect(token).to be_present
      expect(signup.token_digest).to eq(WaitlistSignup.digest(token))
      expect(signup.attributes.values).not_to include(token)
    end

    it "normalises the address, so one mailbox cannot take two places" do
      join(email: "  Person@Example.COM ")

      expect(WaitlistSignup.sole.email).to eq("person@example.com")
    end
  end

  describe "an address that is already waiting" do
    let!(:existing) { create(:waitlist_signup, email: "waiting@example.com", confirmation_sent_at: 1.hour.ago) }

    it "resends rather than failing on the unique index" do
      expect { join(email: "waiting@example.com") }
        .to change { ActionMailer::Base.deliveries.size }.by(1)
      expect(WaitlistSignup.count).to eq(1)
    end

    # Otherwise the previous email and the new one both work, and the person is
    # looking at the newer of the two.
    it "invalidates the previous link" do
      before_digest = existing.token_digest

      join(email: "waiting@example.com")

      expect(existing.reload.token_digest).not_to eq(before_digest)
    end

    # THE ANTI-ABUSE HALF. Without it the form is a button that delivers our
    # mail to an address the sender does not own, as often as they like.
    it "refuses to resend inside the cooldown" do
      existing.update!(confirmation_sent_at: 1.minute.ago)

      expect { join(email: "waiting@example.com") }
        .not_to change { ActionMailer::Base.deliveries.size }
    end

    it "still reports success inside the cooldown" do
      existing.update!(confirmation_sent_at: 1.minute.ago)

      expect(join(email: "waiting@example.com")).to eq(Dry::Monads::Success(:recently_sent))
    end
  end

  describe "an address that already confirmed" do
    before { create(:waitlist_signup, :confirmed, email: "member@example.com") }

    it "sends nothing" do
      expect { join(email: "member@example.com") }
        .not_to change { ActionMailer::Base.deliveries.size }
    end

    it "succeeds, because the caller must not be able to tell" do
      expect(join(email: "member@example.com")).to eq(Dry::Monads::Success(:already_confirmed))
    end
  end

  describe "input the form should never send" do
    it "refuses an address that is not one" do
      result = join(email: "not-an-address")

      expect(result).to be_failure
      expect(WaitlistSignup.count).to be_zero
    end

    it "refuses a blank address" do
      expect(join(email: "")).to be_failure
    end

    # The hidden field is rewritable by anyone with a browser, so the list it
    # names is validated rather than trusted.
    it "refuses a feature that is not in the catalogue" do
      expect(join(email: "new@example.com", feature: "something_else")).to be_failure
    end

    it "drops a key nobody declared" do
      join(email: "new@example.com", confirmed_at: 1.year.ago)

      expect(WaitlistSignup.sole).not_to be_confirmed
    end
  end
end
