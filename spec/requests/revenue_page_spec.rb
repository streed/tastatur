require "rails_helper"

# The revenue-attribution marketing page, in both formats. The claims it makes
# are bound by docs/privacy/claims.md; the assertions here pin the two easiest
# to break by accident: that the page never drifts into calling the revenue
# side anonymous, and that the code examples stay in sync with the docs' API.
RSpec.describe "Revenue marketing page", type: :request do
  it "is public and renders the integration steps" do
    get revenue_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("tastatur.attribution()")
    expect(response.body).to include("/api/v1/identify")
    expect(response.body).to include("checkoutMetadata")
  end

  it "serves markdown at /revenue.md with the same examples" do
    get revenue_path(format: :md)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/markdown")
    expect(response.body).to include("tastatur.attribution()")
    expect(response.body).to include("checkoutMetadata")
  end

  it "carries the metadata block and points machines at the markdown copy" do
    get revenue_path

    expect(response.body).to include('rel="alternate"')
    expect(response.body).to include("/revenue.md")
    expect(response.body).to include('name="description"')
  end

  # claims.md: the revenue side is identifiable and must say so. "not anonymous"
  # appearing in the honesty block is the load-bearing sentence; a rewrite that
  # loses it is a rewrite that starts overclaiming.
  it "states plainly that the revenue side is not anonymous" do
    get revenue_path

    expect(response.body).to include("not anonymous")
  end
end
