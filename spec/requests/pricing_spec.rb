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

  describe "where there is nothing to sell" do
    # Both reasons, because they are different states that must reach the same place:
    # a self-hosted install has switched billing off, and a hosted one with no Stripe
    # keys has not finished switching it on. Publishing prices an instance cannot
    # charge is worse than publishing none — it is an offer that fails at the button.
    it "does not exist on a self-hosted install" do
      allow(Tastatur).to receive(:self_hosted?).and_return(true)
      # `needs_first_run_setup?` rather than creating a user: that predicate is
      # `self_hosted? && !User.exists?`, so the example would otherwise depend on the
      # users table being empty — a whole-suite property no example controls. The
      # non-transactional `:continuous_aggregate` specs can leave a row behind, and
      # then this passed or failed on the random seed.
      allow(Tastatur).to receive(:needs_first_run_setup?).and_return(false)

      get "/pricing"

      expect(response).to redirect_to(root_path)
    end

    it "does not exist when Stripe is not configured" do
      allow(Tastatur).to receive(:billing_enabled?).and_return(false)

      get "/pricing"

      expect(response).to redirect_to(root_path)
    end

    # The first-run wizard is registered on ApplicationController and therefore runs
    # before this controller's own guard, so on a brand-new self-hosted install the
    # setup screen wins. Asserted because both redirects are "correct" and it would
    # otherwise be unclear which one a reader should expect.
    it "is superseded by the setup wizard when one is pending" do
      allow(Tastatur).to receive(:self_hosted?).and_return(true)
      allow(Tastatur).to receive(:needs_first_run_setup?).and_return(true)

      get "/pricing"

      expect(response).to redirect_to(first_run_path)
    end
  end

  def number_with_delimiter(value) = ActiveSupport::NumberHelper.number_to_delimited(value)
end
