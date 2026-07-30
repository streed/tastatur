FactoryBot.define do
  factory :membership do
    account
    user
    role { "member" }

    Membership::ROLES.each { |r| trait(r.to_sym) { role { r } } }
  end
end
