require "rails_helper"

# Both legal documents rendered `Date.current`, so they claimed to have been
# revised today — on every request, forever. That is worse than showing no date:
# a reader checking whether the terms changed since they agreed to them is told
# "today" regardless, and a document that appears to be revised daily invites the
# question of what keeps changing.
RSpec.describe "Legal document dates", type: :request do
  around do |example|
    saved = ENV.delete("LEGAL_UPDATED_ON")
    Tastatur.reset_legal!
    example.run
    saved.nil? ? ENV.delete("LEGAL_UPDATED_ON") : ENV["LEGAL_UPDATED_ON"] = saved
    Tastatur.reset_legal!
  end

  def set_updated_on(value)
    ENV["LEGAL_UPDATED_ON"] = value
    Tastatur.reset_legal!
  end

  %w[/terms /privacy-policy].each do |path|
    context path do
      it "shows no date when none is configured" do
        get path

        expect(response.body).not_to include("Last updated")
      end

      it "never claims to have been updated today" do
        get path

        expect(response.body).not_to include(Date.current.to_fs(:long))
      end

      it "shows the configured date" do
        set_updated_on("2026-03-14")

        get path

        expect(response.body).to include("Last updated March 14, 2026")
      end

      it "shows no date rather than crashing on an unparseable value" do
        set_updated_on("last tuesday")   # Date.parse would read this as a real date

        get path

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("Last updated")
      end
    end
  end

  describe "Tastatur.legal[:updated_on]" do
    it "is a Date when configured" do
      set_updated_on("2026-03-14")

      expect(Tastatur.legal[:updated_on]).to eq(Date.new(2026, 3, 14))
    end

    it "is nil when unset" do
      expect(Tastatur.legal[:updated_on]).to be_nil
    end

    it "is nil when malformed" do
      set_updated_on("nonsense")

      expect(Tastatur.legal[:updated_on]).to be_nil
    end
  end
end
