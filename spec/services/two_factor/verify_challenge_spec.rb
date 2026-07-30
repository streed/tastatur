require "rails_helper"

RSpec.describe TwoFactor::VerifyChallenge do
  let(:user) { create(:user, :with_two_factor) }

  # Sets a known code directly rather than going through IssueChallenge, so these
  # examples are about judging a code and not about issuing one.
  def issue(code, expires_in: TwoFactor::IssueChallenge::CODE_TTL)
    user.update!(
      two_factor_code: code,
      two_factor_code_sent_at: Time.current,
      two_factor_code_expires_at: expires_in.from_now,
      two_factor_failed_attempts: 0
    )
  end

  describe "the correct code" do
    before { issue("123456") }

    it "succeeds" do
      expect(described_class.call(user: user, code: "123456")).to eq(Dry::Monads::Success(user))
    end

    # Replay is the failure this prevents: a code read over somebody's shoulder,
    # or lifted from a mailbox, must be worth exactly one sign-in.
    it "consumes the code, so the same one cannot be used twice" do
      described_class.call(user: user, code: "123456")

      expect(user.reload.two_factor_code_digest).to be_nil
      expect(described_class.call(user: user, code: "123456")).to eq(Dry::Monads::Failure(:no_challenge))
    end
  end

  describe "the wrong code" do
    before { issue("123456") }

    it "fails and spends one attempt" do
      expect(described_class.call(user: user, code: "000000")).to eq(Dry::Monads::Failure(:invalid))
      expect(user.reload.two_factor_failed_attempts).to eq(1)
    end

    it "leaves the code usable while attempts remain" do
      described_class.call(user: user, code: "000000")

      expect(described_class.call(user: user, code: "123456")).to be_success
    end

    it "destroys the code on the last attempt rather than locking the account" do
      (TwoFactor::IssueChallenge::MAX_ATTEMPTS - 1).times do
        expect(described_class.call(user: user, code: "000000")).to eq(Dry::Monads::Failure(:invalid))
      end

      expect(described_class.call(user: user, code: "000000")).to eq(Dry::Monads::Failure(:too_many_attempts))
      expect(user.reload.two_factor_code_digest).to be_nil

      # The account itself is untouched. Locking here would let anybody who knows
      # an email address deny its owner a sign-in, which is a worse outcome than
      # making them wait for a new code.
      expect(user.reload.access_locked?).to be(false)
      expect(user.reload.two_factor_enabled?).to be(true)
    end

    it "refuses even the right code once the budget is spent" do
      TwoFactor::IssueChallenge::MAX_ATTEMPTS.times { described_class.call(user: user, code: "000000") }

      expect(described_class.call(user: user, code: "123456")).to eq(Dry::Monads::Failure(:no_challenge))
    end
  end

  describe "an expired code" do
    it "is refused as expired, not as wrong" do
      issue("123456", expires_in: -1.second)

      expect(described_class.call(user: user, code: "123456")).to eq(Dry::Monads::Failure(:expired))
    end

    it "expires on the far side of the window and not before" do
      issue("123456")

      travel_to(TwoFactor::IssueChallenge::CODE_TTL.from_now - 1.second) do
        expect(described_class.call(user: user.reload, code: "123456")).to be_success
      end

      issue("123456")

      travel_to(TwoFactor::IssueChallenge::CODE_TTL.from_now + 1.second) do
        expect(described_class.call(user: user.reload, code: "123456")).to eq(Dry::Monads::Failure(:expired))
      end
    end

    it "clears the challenge, so a reload issues a fresh one instead of looping" do
      issue("123456", expires_in: -1.second)

      described_class.call(user: user, code: "123456")

      expect(user.reload.two_factor_challenge_pending?).to be(false)
      expect(user.reload.two_factor_code_digest).to be_nil
    end
  end

  describe "no challenge at all" do
    it "fails rather than raising" do
      expect(described_class.call(user: user, code: "123456")).to eq(Dry::Monads::Failure(:no_challenge))
    end

    # `BCrypt::Password.new(nil)` raises, and a raise on the sign-in path is a
    # 500 that anybody can produce by posting to the challenge endpoint.
    it "does not raise when the digest is absent" do
      expect { described_class.call(user: user, code: "123456") }.not_to raise_error
    end
  end
end
