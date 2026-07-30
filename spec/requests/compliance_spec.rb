require "rails_helper"

RSpec.describe "Compliance and legal pages", type: :request do
  # All four are reachable without an account, on purpose: the most common reader
  # is a visitor to a customer's site, or someone deciding whether to sign up.
  describe "public reachability" do
    {
      "/privacy" => "What Tastatur collects",
      "/privacy-policy" => "Privacy policy",
      "/terms" => "Terms and conditions",
      "/dpa" => "Data Processing Agreement",
      "/data-request" => "What we hold about you",
      "/docs" => "Using Tastatur"
    }.each do |path, heading|
      it "serves #{path} with no session" do
        get path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(heading)
      end
    end
  end

  describe "the two different privacy documents" do
    # Conflating these is the likeliest way for a reader to fail to find what
    # they came for, so each page says which is which.
    it "distinguishes account-holder data from visitor data" do
      get "/privacy-policy"

      expect(response.body).to include("account holders")
      expect(response.body).to include("visitors to measured websites")
      expect(response.body).to include(privacy_path)
    end
  end

  describe "unconfigured legal identity" do
    LEGAL_KEYS = %w[LEGAL_ENTITY LEGAL_ADDRESS LEGAL_EMAIL LEGAL_JURISDICTION LEGAL_DPO_EMAIL].freeze

    # Clear the variables explicitly rather than assuming they are absent. The
    # hosted instance sets them in its container environment, so a spec that
    # relied on ambient state passed locally and failed there — which is the
    # wrong way round for a spec whose whole subject is a missing configuration.
    around do |example|
      saved = LEGAL_KEYS.to_h { |key| [key, ENV.delete(key)] }
      Tastatur.reset_legal!
      example.run
      saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      Tastatur.reset_legal!
    end

    # A policy naming nobody, and terms governed by no jurisdiction, are worse
    # than none: they look like diligence while providing neither the disclosure
    # the law requires nor the protection the operator wanted. So an
    # unconfigured instance must say so on the page.
    # The DPA names a processor too, so publishing it with the entity blank puts an
    # agreement in front of a customer that identifies nobody. It was the one legal
    # page missing this check.
    it "warns loudly on the DPA" do
      get "/dpa"

      expect(response.body).to include("not configured")
    end

    it "warns loudly on the terms page" do
      get "/terms"

      expect(response.body).to include("This document is not configured")
      expect(response.body).to include("LEGAL_JURISDICTION")
    end

    it "warns loudly on the privacy policy" do
      get "/privacy-policy"
      expect(response.body).to include("This document is not configured")
    end

    it "renders visibly unfilled placeholders rather than a plausible fake name" do
      get "/terms"

      expect(response.body).to include("NOT CONFIGURED")
      expect(response.body).not_to match(/Example Ltd|Acme Ltd|Your Company Ltd/)
    end
  end

  describe "configured legal identity" do
    around do |example|
      ENV["LEGAL_ENTITY"] = "Reed Analytics Ltd"
      ENV["LEGAL_EMAIL"] = "privacy@tastatur.test"
      ENV["LEGAL_JURISDICTION"] = "England and Wales"
      Tastatur.reset_legal!
      example.run
      ENV.delete("LEGAL_ENTITY")
      ENV.delete("LEGAL_EMAIL")
      ENV.delete("LEGAL_JURISDICTION")
      Tastatur.reset_legal!
    end

    it "drops the warning and names the entity" do
      get "/terms"

      expect(response.body).not_to include("This document is not configured")
      expect(response.body).to include("Reed Analytics Ltd")
      expect(response.body).to include("England and Wales")
    end

    it "still marks a genuinely optional unset field as unfilled" do
      get "/privacy-policy"

      expect(Tastatur.legal_value(:address)).to include("NOT CONFIGURED")
      expect(response.body).to include("privacy@tastatur.test")
    end
  end

  describe "claims we must never make" do
    # docs/privacy/claims.md is the authority. These are the phrases that get
    # privacy-first analytics tools into trouble, and they are easy to reintroduce
    # by accident in a copy edit.
    BANNED = [
      /no cookie banner (is )?(needed|required)/i,
      /100% GDPR compliant/i,
      /fully anonymous/i,
      /GDPR[- ]certified/i,
      /CNIL[- ]approved/i,
      /you (do not|don't) need a DPA/i
    ].freeze

    # A page may QUOTE a banned phrase in order to disown it, and /privacy does
    # exactly that: it names "fully anonymous" to explain why it will not use the
    # term. Quoting a claim is the opposite of making it, so quoted occurrences
    # are removed before checking. Anything asserted bare still fails.
    def claims_in(body)
      body.gsub(/&quot;[^&]{0,80}&quot;/, "").gsub(/"[^"]{0,80}"/, "")
    end

    %w[/ /privacy /privacy-policy /terms /dpa /docs].each do |path|
      it "makes none of them on #{path}" do
        get path
        asserted = claims_in(response.body)

        BANNED.each do |phrase|
          expect(asserted).not_to match(phrase),
                                  "#{path} asserts a claim banned by docs/privacy/claims.md: #{phrase.inspect}"
        end
      end
    end

    it "still catches a banned claim asserted without quotes" do
      # Guards the guard: if the quote-stripping above were too broad, the whole
      # check would silently pass on everything.
      expect(claims_in("<p>Tastatur is fully anonymous.</p>")).to match(/fully anonymous/i)
    end

    # The inverse overreach, and easier to write by accident because it sounds
    # conservative. The callout originally read "You do need one of these"
    # unqualified, which is wrong for a self-hoster (no separate processor at all)
    # and for anyone outside GDPR scope (Art.28(3) does not bind them).
    describe "the DPA obligation is scoped, not asserted flatly" do
      it "does not claim a DPA is universally required" do
        get "/dpa"
        expect(response.body).not_to match(/You do need one of these\.<\/strong>\s*Art\.28\(3\) requires/)
      end

      it "tells a self-hoster the document mostly does not apply to them" do
        get "/dpa"

        expect(response.body).to match(/Self-hosting.{0,60}need none of this/m)
        expect(response.body).to include("no separate")
      end

      it "conditions the requirement on the hosted service and GDPR scope" do
        get "/dpa"

        expect(response.body).to match(/hosted service.{0,80}GDPR/m)
        expect(response.body).to match(/if neither the GDPR nor the UK GDPR applies to you/i)
      end
    end

    it "states the honest pseudonymous-versus-unlinkable distinction" do
      get "/privacy"

      expect(response.body).to include("pseudonymous")
      expect(response.body).to include("unlinkable")
    end

    it "admits that an IP address reaches the server" do
      get "/privacy"
      expect(response.body).to match(/IP address.{0,80}(reach|server)/m)
    end
  end

  describe "the DB-IP attribution required by CC BY 4.0" do
    it "appears on the privacy page" do
      get "/privacy"
      expect(response.body).to include("DB-IP")
    end
  end
end
