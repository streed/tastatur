require "rails_helper"

RSpec.describe "Installation screen", type: :request do
  let(:user) { create(:user) }
  let(:account) { create(:account) }
  let(:site) { create(:site, account: account, domain: "fresh.example.com") }

  before do
    create(:membership, account: account, user: user, role: "owner")
    sign_in user
  end

  def get_frame(path)
    get path, headers: { "Turbo-Frame" => "install_status" }
  end

  describe "before any data arrives" do
    it "shows the waiting state" do
      get "/sites/#{site.to_param}/installation"

      expect(response.body).to include("Waiting for your first pageview")
      expect(response.body).to include(%(turbo-frame id="install_status"))
    end

    # THE REGRESSION THIS FILE EXISTS FOR.
    #
    # Turbo replaces a frame with the matching <turbo-frame> element from the
    # response. When the response contains no frame with that id, Turbo empties
    # the frame instead of raising — so a bare partial made the waiting card
    # disappear after five seconds, with no data sent and nothing in the log. It
    # looked exactly like success.
    it "returns a matching turbo-frame when polled, so Turbo does not blank it" do
      get_frame "/sites/#{site.to_param}/installation"

      expect(response.body).to include(%(turbo-frame id="install_status")),
                               "the polled response has no matching frame; Turbo will empty the card"
      expect(response.body).to include("Waiting for your first pageview")
    end

    it "keeps the poll controller on the card so it continues polling" do
      get_frame "/sites/#{site.to_param}/installation"
      expect(response.body).to include(%(data-controller="poll"))
    end

    it "does not claim to be receiving data" do
      get_frame "/sites/#{site.to_param}/installation"
      expect(response.body).not_to include("Receiving data")
    end
  end

  describe "once the first event has arrived" do
    before { site.update!(first_event_at: 2.minutes.ago) }

    it "flips to the success state" do
      get_frame "/sites/#{site.to_param}/installation"

      expect(response.body).to include("Receiving data")
      expect(response.body).not_to include("Waiting for your first pageview")
    end

    # Polling stops because the success markup carries no controller, rather than
    # because something remembered to switch it off.
    it "drops the poll controller so polling stops" do
      get_frame "/sites/#{site.to_param}/installation"
      expect(response.body).not_to include(%(data-controller="poll"))
    end

    it "still returns a matching frame" do
      get_frame "/sites/#{site.to_param}/installation"
      expect(response.body).to include(%(turbo-frame id="install_status"))
    end
  end

  describe "the snippet" do
    it "shows the site's public token, not its id" do
      get "/sites/#{site.to_param}/installation"

      expect(response.body).to include(site.public_token)
      expect(response.body).to include(Tastatur.tracker_url)
    end

    # The snippet is displayed for copying, so it must be escaped rather than
    # rendered as a live script tag on our own page.
    it "escapes the snippet instead of emitting a real script tag" do
      get "/sites/#{site.to_param}/installation"

      expect(response.body).to include("data-site=&quot;#{site.public_token}&quot;")
      expect(response.body).not_to include(%(<script defer data-site="#{site.public_token}"))
    end
  end

  describe "an end-to-end install" do
    it "goes from waiting to receiving after one real beacon" do
      get_frame "/sites/#{site.to_param}/installation"
      expect(response.body).to include("Waiting for your first pageview")

      post "/api/event",
           params: { s: site.public_token, u: "https://fresh.example.com/" }.to_json,
           headers: { "CONTENT_TYPE" => "text/plain",
                      "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh) Chrome/131.0.0.0" }
      Ingest::WriteBuffer.flush!

      get_frame "/sites/#{site.to_param}/installation"
      expect(response.body).to include("Receiving data")
    end
  end
end
