require "rails_helper"

RSpec.describe "About page", type: :request do
  it "is public" do
    get "/about"
    expect(response).to have_http_status(:ok)
  end

  it "credits the maintainer" do
    get "/about"

    expect(response.body).to include("Reedster LLC")
    expect(response.body).to include("reedster.llc")
    expect(response.body).to include("Solve human problems with software")
  end

  it "gives the origin story in the first person" do
    get "/about"

    expect(response.body).to include("portfolio of projects")
    expect(response.body).to include("Sean Reed")
  end

  it "links to the source, which is what makes the privacy claims checkable" do
    get "/about"
    expect(response.body).to include("github.com/streed/tastatur")
  end

  # Authorship and operator are different facts. Reedster wrote the software,
  # which is true of every copy; who is responsible for the data in a given
  # instance depends on who is running it. A self-hoster reading this page must
  # not come away thinking Reedster is their data controller.
  describe "the authorship/operator distinction" do
    it "states them separately" do
      get "/about"

      expect(response.body).to include("Built and maintained by")
      expect(response.body).to include("This instance")
    end

    context "when no operator is configured" do
      before { allow(Tastatur).to receive(:legal_configured?).and_return(false) }

      it "says so rather than naming Reedster as the operator" do
        get "/about"

        expect(response.body).to include("has not been configured yet")
        expect(response.body).not_to include("Operated by")
      end
    end

    # A self-hosted install has no marketing site: a page selling the hosted
    # service has nothing to say on somebody's own hardware.
    it "does not exist on a self-hosted install" do
      allow(Tastatur).to receive(:self_hosted?).and_return(true)
      allow(Tastatur).to receive(:needs_first_run_setup?).and_return(false)

      get "/about"

      expect(response).to have_http_status(:not_found)
    end

    context "when an operator is configured" do
      before do
        allow(Tastatur).to receive(:legal_configured?).and_return(true)
        allow(Tastatur).to receive(:legal_value).with(:entity).and_return("Someone Else Ltd")
      end

      it "names that operator rather than the maintainer" do
        get "/about"
        expect(response.body).to include("Someone Else Ltd")
      end
    end
  end

  it "is reachable from the footer on every page" do
    get "/"
    expect(response.body).to include(%(href="/about"))
    expect(response.body).to include("Built by")
  end
end
