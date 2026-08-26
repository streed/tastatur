require "rails_helper"

# What a password has to survive to be accepted.
#
# The sign-in form is already about as well defended against guessing as it gets
# — Rack::Attack allows five attempts per twenty seconds by client AND by
# address, lockable follows, bcrypt is at cost 12. None of that touches
# credential stuffing, where the attacker already has the password and is only
# looking for the account it opens. That is what these rules are for, which is
# why they live on the model rather than on the form.
RSpec.describe "Password policy" do
  def build_user(password, email: "person@example.test", name: nil)
    build(:user, email: email, name: name, password: password, password_confirmation: password)
  end

  describe "length" do
    it "refuses eleven characters" do
      expect(build_user("kx7-vqnr-tz")).not_to be_valid
    end

    it "accepts twelve" do
      expect(build_user("kx7-vqnr-tzp")).to be_valid
    end
  end

  describe "the deny list" do
    # Long enough to clear the minimum, and on every published breach corpus.
    %w[
      correcthorsebatterystaple
      passwordpassword
      administrator
      qwertyuiop
      welcome123
      summer2026
    ].each do |listed|
      it "refuses #{listed.inspect}" do
        user = build_user(listed)

        expect(user).not_to be_valid
        expect(user.errors[:password].join).to include("commonly used")
      end
    end

    it "is case-insensitive, because a capital letter is not a decision" do
      expect(build_user("PasswordPassword")).not_to be_valid
    end

    # An operator pointing COMMON_PASSWORD_LIST at a path that does not exist
    # has made a configuration mistake. Failing closed would take registration
    # and password reset down over a typo in a hardening setting.
    it "degrades to a warning rather than locking everybody out of a bad path" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("COMMON_PASSWORD_LIST").and_return("/no/such/list.txt")
      Passwords::DenyList.reload!

      expect(Passwords::DenyList.entries).to be_empty
      expect(build_user("passwordpassword")).to be_valid
    ensure
      allow(ENV).to receive(:[]).with("COMMON_PASSWORD_LIST").and_return(nil)
      Passwords::DenyList.reload!
    end
  end

  # Length is not entropy. Each of these clears twelve characters and is worth a
  # handful of guesses.
  describe "patterns that are long without being secret" do
    it "refuses a password made of too few distinct characters" do
      expect(build_user("ababababababab")).not_to be_valid
    end

    it "refuses a run through the alphabet" do
      expect(build_user("qrstuvwxyzab")).not_to be_valid
    end

    it "refuses a run down the number row" do
      expect(build_user("hj987654321x")).not_to be_valid
    end

    it "leaves an ordinary passphrase alone" do
      expect(build_user("thicket lantern gravel")).to be_valid
    end
  end

  describe "a password that echoes its owner" do
    it "refuses one containing the email local part" do
      user = build_user("marchbanks-2026x", email: "marchbanks@example.test")

      expect(user).not_to be_valid
      expect(user.errors[:password].join).to include("email address or name")
    end

    it "refuses one containing the name" do
      user = build_user("wilhelmina-forever", email: "w@example.test", name: "Wilhelmina")

      expect(user).not_to be_valid
    end

    # Refusing every password containing a three-letter fragment of somebody's
    # address would refuse a great many good ones.
    it "ignores fragments too short to mean anything" do
      user = build_user("thicket lantern gravel", email: "ana@example.test")

      expect(user).to be_valid
    end
  end

  # :validatable runs only when a password is being set. Somebody who chose a
  # short one before this existed keeps signing in until they change it —
  # forcing a reset on everybody would be a security email indistinguishable
  # from a phishing email.
  describe "existing accounts" do
    it "does not invalidate a user whose stored password predates the rule" do
      user = create(:user)
      user.update_columns(encrypted_password: BCrypt::Password.create("short1"))

      expect(user.reload).to be_valid
      expect(user.valid_password?("short1")).to be(true)
    end
  end
end
