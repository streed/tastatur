FactoryBot.define do
  factory :campaign do
    site
    sequence(:name) { |n| "Campaign #{n}" }
    # Explicit rather than derived from the name, so a spec that cares about the
    # tag sets it and a spec that does not still gets a value the scrubber
    # keeps — `Campaign 12`.parameterize is `campaign-12`, which is fine, but a
    # factory that relies on a callback to fill a NOT NULL column breaks
    # silently the day the callback moves.
    sequence(:utm_campaign) { |n| "launch-#{n}" }
  end
end
