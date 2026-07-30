require "rails_helper"

RSpec.describe TwoFactor::IssueChallenge do
  let(:user) { create(:user, :with_two_factor) }

  # The code exists in exactly one place a spec can read it: the email. That is
  # the same constraint the application works under, and reading it from the mail
  # rather than from the database is what proves the digest is a digest.
  def emailed_code
    perform_enqueued_jobs { yield }
    ActionMailer::Base.deliveries.last.subject[/\d{6}/]
  end

  before { ActionMailer::Base.deliveries.clear }

  describe "success" do
    it "stores a digest and an expiry, and emails the code" do
      code = emailed_code { described_class.call(user: user) }

      user.reload
      expect(code).to match(/\A\d{6}\z/)
      expect(user.two_factor_code_digest).to be_present
      expect(user.two_factor_code_digest).not_to include(code), "the code must not be stored in the clear"
      expect(user.authenticate_two_factor_code(code)).to be_truthy
      expect(user.two_factor_code_expires_at).to be_within(5.seconds).of(described_class::CODE_TTL.from_now)
    end

    it "returns Success with the user" do
      expect(described_class.call(user: user)).to eq(Dry::Monads::Success(user))
    end

    it "sends the mail on the tier that has somebody waiting on it" do
      expect { described_class.call(user: user) }
        .to have_enqueued_job(ActionMailer::MailDeliveryJob).on_queue("within_5_seconds")
    end

    # The whole reason there is a per-code attempt budget rather than a per-user
    # one: a fresh code must be a fresh five guesses, not a continuation.
    it "resets the attempt counter" do
      user.update!(two_factor_failed_attempts: 4)

      described_class.call(user: user)

      expect(user.reload.two_factor_failed_attempts).to eq(0)
    end

    it "invalidates the previous code rather than accepting either" do
      first = emailed_code { described_class.call(user: user) }
      travel_to(described_class::RESEND_INTERVAL.from_now + 1.second) do
        second = emailed_code { described_class.call(user: user) }

        expect(second).not_to eq(first)
        expect(user.reload.authenticate_two_factor_code(first)).to be_falsey
        expect(user.reload.authenticate_two_factor_code(second)).to be_truthy
      end
    end

    # Not decoration. `rand(100_000..999_999)` is the obvious implementation and
    # it silently discards a tenth of the keyspace, which no output ever reveals.
    it "can produce a code with a leading zero" do
      allow(SecureRandom).to receive(:random_number).and_return(42)

      code = emailed_code { described_class.call(user: user) }

      expect(code).to eq("000042")
    end
  end

  describe "failure" do
    it "refuses when the user has not switched two-factor on" do
      plain = create(:user)

      expect(described_class.call(user: plain)).to eq(Dry::Monads::Failure(:not_enabled))
      expect(plain.reload.two_factor_code_digest).to be_nil
    end

    it "refuses a second code inside the resend interval" do
      described_class.call(user: user)
      digest = user.reload.two_factor_code_digest

      expect(described_class.call(user: user)).to eq(Dry::Monads::Failure(:too_soon))
      expect(user.reload.two_factor_code_digest).to eq(digest), "the outstanding code must survive a refused resend"
    end

    it "sends no mail when it refuses" do
      described_class.call(user: user)
      ActionMailer::Base.deliveries.clear

      expect { perform_enqueued_jobs { described_class.call(user: user) } }
        .not_to change { ActionMailer::Base.deliveries.size }
    end

    it "allows another once the interval has passed" do
      described_class.call(user: user)

      travel_to(described_class::RESEND_INTERVAL.from_now + 1.second) do
        expect(described_class.call(user: user)).to be_success
      end
    end
  end
end
