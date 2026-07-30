require "rails_helper"

# The failure this exists to prevent, measured on a production-mode boot with
# RESEND_API_KEY blank:
#
#   User#save! raised Resend::Error::InvalidRequestError: API key is invalid
#   ...but the account persisted, because Devise sends the confirmation from an
#      after_commit hook and the transaction had already committed
#   ...unconfirmed, unable to sign in, with its email address permanently taken
#
# So the first person to sign up on a self-hosted instance with no mail provider
# got a 500, a dead account, and no way to re-register. That person is usually the
# operator installing the thing.
RSpec.describe MailDelivery::Logged do
  let(:logger) { instance_double(ActiveSupport::Logger, warn: nil) }

  before { allow(Rails).to receive(:logger).and_return(logger) }

  def logged_output
    messages = []
    allow(logger).to receive(:warn) { |message| messages << message.to_s }
    yield
    messages.join("\n")
  end

  let(:mail) do
    Mail.new do
      to "someone@example.com"
      from "no-reply@tastatur.test"
      subject "Confirm your account"
      body 'Visit <a href="https://tastatur.test/users/confirmation?confirmation_token=abc123">here</a> to confirm.'
    end
  end

  it "does not raise, which is the entire point" do
    expect { described_class.new.deliver!(mail) }.not_to raise_error
  end

  it "returns the message, as a delivery method must" do
    expect(described_class.new.deliver!(mail)).to eq(mail)
  end

  it "records who it was for and what it said" do
    output = logged_output { described_class.new.deliver!(mail) }

    expect(output).to include("MAIL NOT SENT")
    expect(output).to include("someone@example.com")
    expect(output).to include("Confirm your account")
  end

  # The link is the only part an operator actually needs, so it is pulled out
  # rather than left for them to find inside a wrapped HTML body.
  it "extracts the link so it can be used" do
    output = logged_output { described_class.new.deliver!(mail) }

    expect(output).to include("links:")
    expect(output).to include("https://tastatur.test/users/confirmation?confirmation_token=abc123")
  end

  # Scoped to the extracted links, not the whole message: the body section below
  # them is the raw source and is supposed to contain the surrounding HTML.
  it "does not glue HTML onto the end of an extracted link" do
    output = logged_output { described_class.new.deliver!(mail) }

    links = output.lines
                  .drop_while { |line| !line.include?("links:") }
                  .drop(1)
                  .take_while { |line| line.start_with?("    http") }
                  .map(&:strip)

    expect(links).to eq(["https://tastatur.test/users/confirmation?confirmation_token=abc123"])
  end

  it "lists each link once" do
    repeated = Mail.new do
      to "a@example.com"
      subject "Twice"
      body 'link <a href="https://tastatur.test/x">https://tastatur.test/x</a>'
    end

    output = logged_output { described_class.new.deliver!(repeated) }

    expect(output.scan("    https://tastatur.test/x").size).to eq(1)
  end

  it "copes with a message that has no links" do
    plain = Mail.new do
      to "a@example.com"
      subject "Nothing to click"
      body "All done."
    end

    output = logged_output { described_class.new.deliver!(plain) }

    expect(output).to include("no links in this message")
  end

  it "prefers the plain-text part of a multipart message" do
    multi = Mail.new do
      to "a@example.com"
      subject "Both"
      text_part { body "the text version https://tastatur.test/text" }
      html_part { body "<p>the html version https://tastatur.test/html</p>" }
    end

    output = logged_output { described_class.new.deliver!(multi) }

    expect(output).to include("https://tastatur.test/text")
    expect(output).not_to include("https://tastatur.test/html")
  end

  describe "the wiring" do
    it "is registered as a delivery method" do
      expect(ActionMailer::Base.delivery_methods).to include(:logged)
    end

    it "leaves resend registered too, so a configured instance still uses it" do
      expect(ActionMailer::Base.delivery_methods).to include(:resend)
    end
  end
end
