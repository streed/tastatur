FactoryBot.define do
  factory :campaign_link do
    site
    sequence(:name) { |n| "Campaign link #{n}" }
    destination_url { "https://#{site.domain}/pricing" }
    utm_source { "newsletter" }
    utm_medium { "email" }
    sequence(:utm_campaign) { |n| "launch-#{n}" }
  end
end
