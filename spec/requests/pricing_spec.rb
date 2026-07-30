require "rails_helper"

RSpec.describe "Pricing", type: :request do
  it "is public" do
    get "/pricing"

    expect(response).to have_http_status(:ok)
  end

  # Read from the catalogue rather than hardcoded, so a price or allowance change
  # cannot leave the page saying one thing and the enforcement doing another.
  it "publishes the real figures for both plans" do
    get "/pricing"

    expect(response.body).to include("$#{Billing::Plan.free.price_display}")
    expect(response.body).to include("$#{Billing::Plan.pro.price_display}")
    expect(response.body).to include(number_with_delimiter(Billing::Plan.free.monthly_event_limit))
    expect(response.body).to include(number_with_delimiter(Billing::Plan.pro.monthly_event_limit))
    expect(response.body).to include(Billing::Plan.pro.site_limit.to_s)
  end

  it "states that teammates are unlimited rather than leaving it to be inferred" do
    get "/pricing"

    expect(response.body).to include("Teammates")
    expect(response.body).to include("Unlimited")
  end

  # These four sentences are promises the code keeps — no overage billing, a warning
  # before the cap, bots excluded, and no data deleted on downgrade. If the page
  # stops saying them, the behaviour is still there but nobody was told.
  it "says what happens at the limit" do
    get "/pricing"

    expect(response.body).to include("no overage charge")
    expect(response.body).to include("80%")
    expect(response.body).to include("Bots do not count")
    expect(response.body).to include("Downgrading never deletes anything")
  end

  it "points at the self-hosted option, which has no limits at all" do
    get "/pricing"

    expect(response.body).to include("Self-host it")
    expect(response.body).to include(Tastatur.maintainer[:source])
  end

  describe "on a self-hosted install" do
    before { allow(Tastatur).to receive(:self_hosted?).and_return(true) }

    it "does not exist, because there is nothing to sell" do
      # A user has to exist, or the first-run setup wizard claims the request before
      # this controller is reached — which is also correct, just a different guard.
      create(:user)

      get "/pricing"

      expect(response).to redirect_to(root_path)
    end

    it "is superseded by the setup wizard on a brand-new install" do
      get "/pricing"

      expect(response).to redirect_to(first_run_path)
    end
  end

  def number_with_delimiter(value) = ActiveSupport::NumberHelper.number_to_delimited(value)
end
