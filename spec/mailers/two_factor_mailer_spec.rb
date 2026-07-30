require "rails_helper"

RSpec.describe TwoFactorMailer do
  let(:user) { create(:user, email: "someone@example.test") }
  let(:mail) { described_class.challenge(user, "042195") }

  it "goes to the account holder with the code in the subject" do
    expect(mail.to).to eq(["someone@example.test"])
    expect(mail.subject).to eq("042195 is your Tastatur sign-in code")
  end

  it "shows the code and how long it lasts" do
    body = mail.body.to_s

    expect(body).to include("042195")
    expect(body).to include((TwoFactor::IssueChallenge::CODE_TTL / 60).to_i.to_s)
  end

  # THE PROPERTY THIS EMAIL IS BUILT AROUND. Every other message this
  # application sends is a button you click. An email that trains people to
  # click through to a sign-in page trains them to click through to somebody
  # else's, and a one-time code is exactly what a phishing page wants. The code
  # is typed into a screen the reader already has open, which is the only shape
  # that survives being forwarded.
  #
  # Asserted as an exact set rather than "no anchors at all", because the shared
  # mailer layout carries two footer links that every email has. Naming them is
  # the point: this fails the day somebody adds "Open Tastatur" to the template,
  # which is the helpful-looking change that would undo the whole argument.
  it "adds no link of its own to the two the layout gives every email" do
    hrefs = mail.body.to_s.scan(/href="([^"]*)"/).flatten

    expect(hrefs).to contain_exactly("#{Tastatur.base_url}/privacy", "#{Tastatur.base_url}/docs"),
                     "a sign-in code email must give the reader nothing to click"
  end

  it "tells the reader what it means if it was not them" do
    expect(mail.body.to_s).to include("somebody knows your password")
  end

  it "is themed and comes from the configured address" do
    expect(mail.body.to_s).to include("#f2f1ec")
    expect(mail.from.first).to eq(ENV.fetch("MAIL_FROM", "no-reply@localhost"))
  end
end
