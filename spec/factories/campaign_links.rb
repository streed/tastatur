FactoryBot.define do
  factory :campaign_link do
    # `site` IS TRANSIENT, and that is the whole design of this factory. Most
    # examples care which site a link is on (the hostname policy, the tenant
    # scope) and not which campaign, so `create(:campaign_link, site: site)`
    # has to keep working — but the link's real `site_id` is copied from its
    # campaign on save, so a factory that set the column directly could produce
    # a link on one site under a campaign on another. That is a state the model
    # now refuses, and it would refuse it in the middle of unrelated examples.
    #
    # So `site:` names the site the CAMPAIGN is on, and the column follows.
    transient do
      site { nil }
    end

    campaign { association(:campaign, **(site ? { site: site } : {})) }

    sequence(:name) { |n| "Link #{n}" }
    destination_url { "https://#{campaign.site.domain}/pricing" }
    utm_source { "newsletter" }
    utm_medium { "email" }
  end
end
