require "rails_helper"

# Tastatur measuring Tastatur, and the one rule that makes that defensible.
#
# The dashboard's instrumentation is annotations on markup, so a leak arrives the
# same way a useful property does: one more attribute on one more link, in a diff
# that looks like every other diff. There is no service to review and no contract
# to fail — the ingest contract bounds the SIZE of a property and has no opinion
# whatever on whether its contents belong to somebody else.
#
# The danger is not hypothetical. In sites/_breakdown the drill-down link is built
# from `row.value`, which is one of the customer's own page paths, and
#
#   analytics_props: { dimension: dimension }
#   analytics_props: { dimension: dimension, value: row.value }
#
# read equally reasonably at review time. The second one puts a customer's URLs,
# referrers and visitors' countries into our analytics database, which is the
# precise thing every page of /privacy says we do not do.
#
# So these examples render the instrumented screens with a customer's data on them
# and then read back ONLY what the annotations would transmit.
RSpec.describe "Self-measurement", type: :request do
  let(:user) { create(:user, email: "owner@northwind.test") }
  let(:account) { create(:account, name: "Northwind Retail") }
  let(:site) do
    create(:site, :receiving, :no_suppression, account: account, domain: "northwind.example.com")
  end

  # A path a customer would not want in anyone else's analytics, and which the
  # dashboard puts on screen in a filter chip, a breakdown row and a link target.
  let(:customer_path) { "/orders/thank-you" }

  before do
    create(:membership, account: account, user: user, role: "owner")
    sign_in user

    delete_all_events
    create_events(site, count: 5, path: customer_path, visitor_prefix: "v", at: 2.hours.ago)
  end

  # Everything on these screens that belongs to the customer rather than to us.
  # The site token is here because it identifies a customer's site as precisely as
  # the domain does, and a top-pages report full of them would be a directory of
  # who we sell to.
  def customer_data
    [site.public_token, site.domain, account.name, user.email, customer_path]
  end

  # Only the attributes the tracker reads. Asserting on the whole page would be
  # meaningless: the domain is in the heading of nearly every screen here, and it
  # belongs there.
  def annotations
    response.body.scan(/data-analytics-(?:event|props)="([^"]*)"/)
            .flatten.map { |value| CGI.unescapeHTML(value) }
  end

  def leaks
    annotations.select { |value| customer_data.any? { |secret| value.include?(secret) } }
  end

  describe "what an annotation may carry" do
    it "reports a filtered dashboard without naming what it is filtered by" do
      get "/sites/#{site.to_param}?page=#{CGI.escape(customer_path)}"

      expect(response).to have_http_status(:ok)
      expect(annotations).to include("Period Changed", "Filter Applied", "Filter Removed", "Filters Cleared")

      # The dimension is the finding — which kinds of breakdown people actually
      # use. The value is the customer's.
      expect(annotations).to include(a_string_matching(/"dimension":"page"/))
      expect(leaks).to be_empty,
                       "the dashboard put a customer's own data in an analytics annotation: #{leaks.inspect}"
    end

    it "reports the rest of the authenticated dashboard the same way" do
      funnel = create(:funnel, site: site)
      goal = create(:goal, site: site)

      %W[
        /sites
        /sites/new
        /sites/#{site.to_param}/edit
        /sites/#{site.to_param}/installation
        /sites/#{site.to_param}/goals
        /sites/#{site.to_param}/goals/new
        /sites/#{site.to_param}/goals/#{goal.to_param}/edit
        /sites/#{site.to_param}/funnels
        /sites/#{site.to_param}/funnels/new
        /sites/#{site.to_param}/funnels/#{funnel.to_param}
        /sites/#{site.to_param}/shared_links
        /account
      ].each do |path|
        get path

        expect(response).to have_http_status(:ok), "#{path} did not render"
        expect(leaks).to be_empty, "#{path} put customer data in an analytics annotation: #{leaks.inspect}"
      end
    end
  end

  describe "the interactions that are reported" do
    it "counts creating a site, a goal, a funnel, a funnel step and a share link" do
      get "/sites/new"
      expect(annotations).to include("Site Added")

      get "/sites/#{site.to_param}/goals/new"
      expect(annotations).to include("Goal Created")

      get "/sites/#{site.to_param}/funnels/new"
      expect(annotations).to include("Funnel Created", "Funnel Step Added", "Funnel Alternative Added")

      get "/sites/#{site.to_param}/shared_links"
      expect(annotations).to include("Share Link Created")
    end

    # The forms are shared between new and edit. Counting an edit under the
    # creation name would make "goals created" larger than the number of goals,
    # which is the kind of number nobody notices is wrong for a year.
    it "does not count editing as creating" do
      goal = create(:goal, site: site)
      funnel = create(:funnel, site: site)

      get "/sites/#{site.to_param}/goals/#{goal.to_param}/edit"
      expect(annotations).not_to include("Goal Created")

      get "/sites/#{site.to_param}/funnels/#{funnel.to_param}/edit"
      expect(annotations).not_to include("Funnel Created")
    end

    it "counts reaching the install snippet and the settings screen" do
      get "/sites/#{site.to_param}"
      expect(annotations).to include("Install Snippet Viewed")

      get "/sites/#{site.to_param}/installation"
      expect(annotations).to include("Site Settings Opened")
    end
  end

  # The public dashboard renders the same breakdown partial with drillable: false,
  # so its rows are plain divs and carry nothing. That is worth an example rather
  # than a comment: those pages are seen by the CUSTOMER'S audience, and measuring
  # a stranger's visitors from inside a product sold on not doing that would be
  # indefensible in a way no property allowlist could fix.
  describe "the public shared dashboard" do
    let(:shared_link) { create(:shared_link, site: site) }

    it "is not instrumented at all" do
      get "/share/#{shared_link.slug}"

      expect(response).to have_http_status(:ok)
      expect(annotations).to be_empty
      expect(response.body).not_to include(%(data-controller="analytics"))
    end

    it "does not carry the tracker even when this instance measures itself" do
      allow(Tastatur).to receive(:self_measurement_token).and_return("ZZZZZZZZZZZZZZZZ")

      get "/share/#{shared_link.slug}"
      expect(response.body).not_to include(%(data-site="ZZZZZZZZZZZZZZZZ"))
    end
  end

  describe "the tracker" do
    it "is absent unless this instance is configured to measure itself" do
      get "/sites"

      expect(response.body).not_to include(Tastatur.tracker_url)
    end

    it "is the same snippet a customer is given, pointed at our own key" do
      allow(Tastatur).to receive(:self_measurement_token).and_return("ZZZZZZZZZZZZZZZZ")

      get "/sites"

      expect(response.body).to include(%(data-site="ZZZZZZZZZZZZZZZZ"))
      expect(response.body).to include(Tastatur.tracker_url)
    end
  end
end
