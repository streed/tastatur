require "rails_helper"

# What `/` is on a deployment with no marketing site.
#
# There is no landing page in this repository, and PagesController#home is where
# the reasoning lives. What is asserted here is the consequence: the root path is
# a front door and nothing else, so it forwards rather than rendering, and it is
# not offered to crawlers as though it were a page.
#
# SKIPPED WHOLESALE WHERE AN EDITION SERVES `/`, because there the root path is
# that edition's landing page and is asserted in the repository that ships it.
# The guard is the predicate — what this deployment *does* — and never a check
# for a directory on disk; see CLAUDE.md §20.
RSpec.describe "The root path", type: :request do
  before { skip "an edition serves a landing page at / on this deployment" if Tastatur.marketing_site? }

  it "sends a visitor who is not signed in to the sign-in form" do
    get "/"

    expect(response).to redirect_to(new_user_session_path)

    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Sign in")
  end

  # The header logo links here from every screen in the application, so this is
  # the common case rather than an edge one. It has to be silent: Devise's own
  # `require_no_authentication` would answer it with "You are already signed in."
  # and a redirect back to `root_path`, which is why `/` is not routed straight
  # into the sessions controller.
  it "sends somebody who is already signed in to their sites, with nothing to say about it" do
    sign_in create(:user)

    get "/"

    expect(response).to redirect_to(sites_path)
    expect(flash).to be_empty
  end

  # A sitemap lists public content. A sign-in form is not content, and an entry
  # that redirects is reported back as an error by every search console — see
  # Seo::BuildSitemap, which lists /docs and the policies here and nothing else.
  it "is not listed in the sitemap" do
    get "/sitemap.xml"

    locs = Nokogiri::XML(response.body).remove_namespaces!.css("url > loc").map(&:text)

    expect(locs).not_to be_empty
    expect(locs).not_to include("http://www.example.com/")
  end
end
