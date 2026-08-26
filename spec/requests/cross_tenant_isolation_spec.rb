require "rails_helper"

# One account's identifiers, presented by another account's user.
#
# Every one of these paths is scoped correctly today — SiteScoped resolves
# through `policy_scope`, so a token belonging to somebody else raises
# RecordNotFound before any authorization question is asked, and every nested
# lookup then goes through that site. This spec does not exist because something
# is wrong. It exists because NOTHING NOTICES when the next controller forgets:
# `verify_policy_scoped` only holds index actions, `verify_authorized` is
# satisfied by an `authorize` call on a record that was fetched unscoped, and
# every individual policy spec passes while asking about records it was handed.
#
# The escalation this suite grew out of survived for the same reason — every
# policy had a spec, and no spec asked all of them the same question at once.
#
# 404, NOT 403, THROUGHOUT. That is the deliberate answer: telling a stranger
# apart "that exists and is not yours" from "that does not exist" is how public
# identifiers become enumerable, which is the whole argument of §10.
RSpec.describe "Cross-tenant isolation", type: :request do
  # THEIRS.
  let(:their_account) { create(:account) }
  let(:their_user) { create(:user) }
  let(:their_site) { create(:site, account: their_account) }

  # OURS. An owner, so nothing below can be mistaken for a mere role refusal —
  # the most privileged role there is still must not reach another tenant.
  let(:our_account) { create(:account) }
  let(:our_user) { create(:user) }
  let!(:our_site) { create(:site, account: our_account) }

  before do
    create(:membership, account: their_account, user: their_user, role: "owner")
    create(:membership, account: our_account, user: our_user, role: "owner")
    sign_in our_user
  end

  def expect_not_found(method, path, **options)
    public_send(method, path, **options)

    expect(response).to have_http_status(:not_found),
                        "#{method.to_s.upcase} #{path} answered #{response.status}, not 404"
  end

  describe "a site that is not ours" do
    it "cannot be read" do
      expect_not_found(:get, "/sites/#{their_site.public_token}")
    end

    it "cannot be updated" do
      expect_not_found(:patch, "/sites/#{their_site.public_token}",
                       params: { site: { domain: "stolen.example" } })
      expect(their_site.reload.domain).not_to eq("stolen.example")
    end

    it "cannot be deleted" do
      expect_not_found(:delete, "/sites/#{their_site.public_token}")
      expect(Site.exists?(their_site.id)).to be(true)
    end

    it "hides its installation snippet, which carries the site token" do
      expect_not_found(:get, "/sites/#{their_site.public_token}/installation")
    end

    it "hides its journeys report" do
      expect_not_found(:get, "/sites/#{their_site.public_token}/journeys")
    end

    it "hides its revenue attribution" do
      expect_not_found(:get, "/sites/#{their_site.public_token}/attribution")
    end
  end

  # The interesting half. Each of these has an identifier of its own, so a
  # controller could resolve the record first and check the site afterwards —
  # or not at all.
  describe "a record nested under a site that is not ours" do
    it "will not show another site's goal" do
      goal = create(:goal, site: their_site)

      expect_not_found(:get, "/sites/#{their_site.public_token}/goals/#{goal.public_id}/edit")
      expect_not_found(:delete, "/sites/#{their_site.public_token}/goals/#{goal.public_id}")
      expect(Goal.exists?(goal.id)).to be(true)
    end

    it "will not show another site's funnel" do
      funnel = create(:funnel, site: their_site)

      expect_not_found(:get, "/sites/#{their_site.public_token}/funnels/#{funnel.public_id}")
    end

    it "will not show another site's dashboard" do
      dashboard = create(:dashboard, site: their_site)

      expect_not_found(:get, "/sites/#{their_site.public_token}/dashboards/#{dashboard.public_id}")
    end

    it "will not list another site's share links, which are unauthenticated URLs" do
      create(:shared_link, site: their_site)

      expect_not_found(:get, "/sites/#{their_site.public_token}/shared_links")
    end

    it "will not list another site's API keys" do
      expect_not_found(:get, "/sites/#{their_site.public_token}/api_keys")
    end

    it "will not list another site's customers, which are identifiable people" do
      expect_not_found(:get, "/sites/#{their_site.public_token}/customers")
    end
  end

  # THE ONE THAT IS NOT NESTED. Campaigns are top level with the site as a
  # parameter (§12), so the tenant check lives in CampaignScreen#current_site
  # rather than in SiteScoped — a second implementation of the same rule, which
  # is exactly the kind that drifts.
  describe "campaigns, where the site is a query parameter" do
    it "404s a site token that is not ours rather than falling back to ours" do
      expect_not_found(:get, "/campaigns?site=#{their_site.public_token}")
    end

    it "will not create a campaign against another site" do
      expect {
        post "/campaigns", params: { site: their_site.public_token,
                                     campaign: { name: "Theirs", utm_campaign: "theirs" } }
      }.not_to change(Campaign, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "will not edit another account's campaign" do
      campaign = create(:campaign, site: their_site)

      expect_not_found(:get, "/campaigns/#{campaign.public_id}/edit")
      expect_not_found(:delete, "/campaigns/#{campaign.public_id}")
      expect(Campaign.exists?(campaign.id)).to be(true)
    end
  end

  # A cross-tenant reference smuggled in through a nested attribute rather than
  # through the URL. The URL is the obvious way in and therefore the guarded
  # one; this is the other way.
  describe "a foreign identifier posted into one of our own records" do
    it "will not point our share link at their dashboard" do
      theirs = create(:dashboard, site: their_site)

      post "/sites/#{our_site.public_token}/shared_links",
           params: { shared_link: { name: "Sneaky", dashboard_public_id: theirs.public_id } }

      expect(our_site.shared_links.count).to be_zero
    end
  end

  # The instance-administration console is gated on User#admin?, which is a
  # different thing from being an admin OF an account — the confusion §11 names
  # explicitly. An account owner is not an operator.
  describe "the admin console" do
    it "is closed to an account owner who is not an instance administrator" do
      get "/admin"

      expect(response).not_to have_http_status(:ok)
    end

    it "does not list other people's users" do
      get "/admin/users"

      expect(response).not_to have_http_status(:ok)
      expect(response.body).not_to include(their_user.email)
    end
  end
end
