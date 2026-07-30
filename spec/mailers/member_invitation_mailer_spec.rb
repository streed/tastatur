require "rails_helper"

# Two cases were previously handled badly and not at all.
#
# A NEW invitee got Devise's bare password-reset email, which out of context reads
# as "somebody tried to reset my password" and never says who invited them or to
# what. An EXISTING user added to an account got nothing whatsoever — their site
# list quietly grew and they were left to notice.
RSpec.describe MemberInvitationMailer do
  let(:account) { create(:account, name: "Northwind") }
  let(:inviter) { create(:user, name: "Ada Lovelace") }
  let(:membership) { create(:membership, account: account, role: "admin") }

  describe "a new invitee" do
    subject(:mail) { described_class.invited(membership, invited_by: inviter, reset_token: "tok123") }

    it "says who added them, where, and as what" do
      expect(mail.subject).to eq("Ada Lovelace added you to Northwind on Tastatur")
      expect(mail.body.to_s).to include("Ada Lovelace").and include("Northwind").and include("admin")
    end

    it "sends them to set a password" do
      expect(mail.body.to_s).to include("Choose a password")
      expect(mail.body.to_s).to include("reset_password_token=tok123")
    end

    # An unexpected account invitation is exactly the shape of a phishing email, so
    # it says what to do about it rather than leaving someone to guess.
    it "tells them what to do if they were not expecting it" do
      expect(mail.body.to_s).to include("not expecting this")
    end

    it "goes to the invitee, from the configured address" do
      expect(mail.to).to eq([membership.user.email])
      expect(mail.from).to eq([ENV.fetch("MAIL_FROM", "no-reply@localhost")])
    end
  end

  describe "someone who already has an account" do
    subject(:mail) { described_class.invited(membership, invited_by: inviter) }

    it "does not ask them to set a password they already have" do
      expect(mail.body.to_s).not_to include("Choose a password")
      expect(mail.body.to_s).not_to include("reset_password_token")
    end

    it "tells them there is nothing to do" do
      expect(mail.body.to_s).to include("nothing to set up")
    end
  end

  it "copes with an unknown inviter rather than saying 'added you'" do
    mail = described_class.invited(membership, invited_by: nil)

    expect(mail.subject).to eq("Someone added you to Northwind on Tastatur")
  end

  it "falls back to the inviter's email when they have no name" do
    nameless = create(:user, name: nil)

    mail = described_class.invited(membership, invited_by: nameless)

    expect(mail.subject).to include(nameless.email)
  end

  describe "Accounts::InviteMember" do
    it "sends one for a brand-new person" do
      expect do
        described_class_result = Accounts::InviteMember.call(
          account: account, email: "brand-new@example.com", role: "member", invited_by: inviter
        )
        expect(described_class_result).to be_success
      end.to have_enqueued_mail(MemberInvitationMailer, :invited)
    end

    it "sends one for a person who already has an account" do
      existing = create(:user)
      create(:membership, user: existing)

      expect do
        Accounts::InviteMember.call(
          account: account, email: existing.email, role: "member", invited_by: inviter
        )
      end.to have_enqueued_mail(MemberInvitationMailer, :invited)
    end

    # The token is generated rather than sent by Devise, so the link in our own
    # email has to actually work. If it did not, an invited person would be stuck
    # with a 32-character random password nobody has ever seen.
    it "issues a reset token that lets a new invitee set a password" do
      Accounts::InviteMember.call(
        account: account, email: "tokencheck@example.com", role: "member", invited_by: inviter
      )
      user = User.find_by(email: "tokencheck@example.com")

      expect(user.reset_password_token).to be_present
      expect(user.reset_password_sent_at).to be_present
    end

    # The membership is real and the person can be told again; failing the whole
    # invitation because mail is down would be the worse outcome.
    it "still adds the member when the email cannot be sent" do
      allow(MemberInvitationMailer).to receive(:invited).and_raise(StandardError, "smtp is down")
      allow(Sentry).to receive(:capture_exception)

      result = Accounts::InviteMember.call(
        account: account, email: "resilient@example.com", role: "member", invited_by: inviter
      )

      expect(result).to be_success
      expect(account.users.map(&:email)).to include("resilient@example.com")
    end
  end
end
