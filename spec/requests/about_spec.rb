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

    context "when self-hosted and unconfigured" do
      before do
        allow(Tastatur).to receive(:self_hosted?).and_return(true)
        allow(Tastatur).to receive(:legal_configured?).and_return(false)
      end

      it "says the operator is not Reedster" do
        get "/about"

        expect(response.body).to include("self-hosted install")
        expect(response.body).to match(/not\s+Reedster LLC/m)
      end
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
