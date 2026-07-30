require "rails_helper"

RSpec.describe Seo::Faq do
  before { allow(Tastatur).to receive(:billing_enabled?).and_return(true) }

  describe "the catalogue" do
    it "gives every entry a unique anchor safe to put in a URL fragment" do
      anchors = described_class.entries.map(&:anchor)

      expect(anchors).to all(match(/\A[a-z0-9-]+\z/))
      expect(anchors.uniq).to eq(anchors)
    end

    it "asks a question and answers it" do
      described_class.entries.each do |entry|
        expect(entry.question).to end_with("?")
        expect(entry.answer).to all(be_present)
      end
    end

    it "can be looked up by anchor, which is what a deep link resolves against" do
      expect(described_class.find("gdpr").question).to eq("Is Tastatur GDPR compliant?")
      expect(described_class.find("nonsense")).to be_nil
    end
  end

  # THE SPEC THIS FILE IS FOR.
  #
  # docs/privacy/claims.md lists the sentences that get privacy-first analytics
  # tools into trouble, and a FAQ is the most likely place in the codebase for
  # one to reappear — because a FAQ is written in the voice of the question, and
  # the question is usually the forbidden claim itself. "Is Tastatur GDPR
  # compliant?" is exactly the phrase somebody types into a search box, and the
  # page has to carry it to be found at all.
  #
  # SO THE BAN APPLIES TO ANSWERS, NOT TO QUESTIONS, and that distinction is the
  # whole design. claims.md governs what this project asserts about itself. A
  # heading quoting a reader's question asserts nothing; the paragraph under it
  # is where a claim gets made, and that is what is checked here.
  describe "the language in the answers" do
    # Each pattern is a phrase claims.md says never to use, paired with what it
    # says to write instead.
    FORBIDDEN = {
      /\bGDPR[- ]compliant\b/i => "compliance is a property of a controller, not of a product",
      /\b100% GDPR\b/i => "no product confers compliance",
      /\b(GDPR|CNIL|ICO)[- ](approved|certified)\b/i => "no such certification exists for this category",
      /no cookie banner (needed|required)/i => "scope it: jurisdiction, configuration, and every other script on the site",
      /\b(fully anonymous|anonymous by design)\b/i => "pseudonymous while the salt lives, unlinkable once destroyed",
      /\bwe collect no personal data\b/i => "an IP address reaches the server and is personal data (Breyer)",
      /\bwe never store IP addresses\b/i => "name the subject: no VISITOR's IP is stored",
      /\bprivacy[- ]friendly\b/i => "name the property instead",
      /\bmore accurate than\b/i => "ours is a good estimate, not a census"
    }.freeze

    FORBIDDEN.each do |pattern, instead|
      it "never says #{pattern.source} — #{instead}" do
        offenders = Seo::Faq.entries.select { |entry| entry.answer_text.match?(pattern) }

        expect(offenders.map(&:anchor)).to be_empty
      end
    end
  end

  # The positive half. claims.md does not only forbid sentences, it requires
  # some — a claim that is technically true and materially incomplete is the
  # failure mode it spends the most words on, because "an incomplete enumeration
  # is worse than a vague sentence".
  describe "the disclosures claims.md requires" do
    def answer(anchor) = described_class.find(anchor).answer_text

    it "admits that IP addresses reach the server and are personal data" do
      expect(answer("personal-data")).to match(/Breyer/)
      expect(answer("personal-data")).to match(/personal data under GDPR/i)
    end

    # "No IP is ever stored" is the sweeping version and it is false: Devise's
    # trackable records an account holder's sign-in IP. Naming the subject makes
    # the strong claim survivable, and disclosing the exception is what stops it
    # reading as a caught lie later.
    it "names the subject of the IP claim and discloses the account-holder exception" do
      expect(answer("ip-addresses")).to match(/No visitor's IP address is ever persisted/i)
      expect(answer("ip-addresses")).to match(/two most recent sign-ins/i)
    end

    it "states the cross-day unique visitor limitation rather than implying otherwise" do
      expect(answer("different-numbers")).to match(/sum of 30 daily figures/i)
    end

    it "scopes the DPA answer instead of overstating the obligation in either direction" do
      dpa = answer("dpa")

      expect(dpa).to match(/hosted service/i)
      expect(dpa).to match(/28\(3\)/)
      expect(dpa).to match(/self-host/i)
    end

    it "states the controller and processor split in both directions" do
      expect(answer("dpa")).to match(/site owner is the controller/i)
      expect(answer("dpa")).to match(/account data.*Tastatur is the controller/im)
    end
  end

  describe "the pricing entry" do
    it "reads its numbers from the plan catalogue rather than repeating them" do
      text = described_class.find("pricing").answer_text

      expect(text).to include("$#{Billing::Plan.pro.price_display}")
      expect(text).to include(
        ActiveSupport::NumberHelper.number_to_delimited(Billing::Plan.pro.monthly_event_limit)
      )
    end

    it "is absent entirely where this instance cannot take a payment" do
      allow(Tastatur).to receive(:billing_enabled?).and_return(false)

      expect(described_class.find("pricing")).to be_nil
      expect(described_class.entries).not_to be_empty
    end
  end

  # Built per call, so a deployment reconfigured after boot is described
  # correctly rather than by whatever was true when the process started. Same
  # reasoning as Billing::Plan#stripe_price_id reading ENV at call time.
  it "reflects the deployment as it is when the page is served, not at boot" do
    with_billing = described_class.entries.size

    allow(Tastatur).to receive(:billing_enabled?).and_return(false)

    expect(described_class.entries.size).to eq(with_billing - 1)
  end
end
