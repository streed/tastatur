require "rails_helper"

RSpec.describe Account do
  # THE GUARD FOR EVERY LIMIT EXAMPLE IN THE SUITE.
  #
  # Plan limits do not apply unless billing is switched on AND configured, so a suite
  # running unconfigured would pass every limit example by measuring nothing — and
  # would keep passing if enforcement were deleted outright. spec/support/stripe.rb
  # establishes the configured state; this fails, by name, if it ever stops.
  it "runs with billing enabled, or every limit example below is vacuous" do
    expect(Tastatur.billing_enabled?).to be(true),
           "billing is disabled in this run, so plan limits are not being enforced and the examples " \
           "below prove nothing. Check spec/support/stripe.rb and STRIPE_PRICE_PRO."
  end

  describe "plan allowances" do
    it "reads every limit from the catalogue rather than from a column" do
      free = create(:account, plan: "free")
      pro = create(:account, plan: "pro")

      expect(free.event_limit).to eq(500_000)
      expect(free.site_limit).to eq(1)
      expect(pro.event_limit).to eq(10_000_000)
      expect(pro.site_limit).to eq(20)
    end

    it "prefers an override to the plan's allowance" do
      account = create(:account, plan: "free", event_limit_override: 750_000, site_limit_override: 7)

      expect(account.event_limit).to eq(750_000)
      expect(account.site_limit).to eq(7)
    end

    # An override of zero is a real instruction — "record nothing for this account"
    # — and it only survives because 0 is truthy in Ruby. Written down as an
    # example because the obvious tidy-up (`event_limit_override.presence`) would
    # silently turn it into the plan's full allowance, which is the opposite of
    # what was asked for and would not fail anything else.
    it "honours an override of zero instead of falling through to the plan" do
      account = create(:account, plan: "free", event_limit_override: 0)

      expect(account.event_limit).to eq(0)
    end

    # The expiry exists so a mid-month downgrade cannot retroactively spend an
    # allowance the customer already paid for: Billing::SyncSubscription grandfathers
    # the rest of the month and dates the grant, rather than leaving it in force
    # forever.
    it "stops honouring an override once its expiry has passed" do
      account = create(:account, plan: "free", event_limit_override: 3_500_000,
                                 event_limit_override_until: 10.days.from_now)
      expect(account.event_limit).to eq(3_500_000)

      account.update!(event_limit_override_until: 1.second.ago)
      expect(account.event_limit).to eq(500_000)
    end

    it "treats an override with no expiry as permanent, which is what support grants" do
      account = create(:account, plan: "free", event_limit_override: 750_000)

      expect(account.event_limit_override_until).to be_nil
      expect(account.event_limit).to eq(750_000)
    end

    it "will not record an expiry with no override behind it" do
      expect { create(:account, event_limit_override_until: 1.day.from_now) }
        .to raise_error(ActiveRecord::StatementInvalid, /event_limit_override_expiry_check/)
    end

    it "refuses a negative event override and a site override below one" do
      expect(build(:account, event_limit_override: -1)).not_to be_valid
      expect(build(:account, site_limit_override: 0)).not_to be_valid
    end
  end

  # Teammates are unlimited on every plan, which is a pricing decision rather than
  # an omission — so it is asserted both as the constant the code reads and as
  # behaviour, because deleting the constant would not fail the first assertion
  # alone.
  describe "teammates" do
    it "declares no member limit on any plan" do
      Billing::Plan::ALL.each do |plan|
        expect(create(:account, plan: plan.key).member_limit).to eq(Billing::Plan::UNLIMITED)
      end
    end

    it "lets a free account hold far more members than any paid tier would allow" do
      account = create(:account, plan: "free")
      create(:membership, account: account, user: create(:user), role: "owner")

      # Users are built by hand rather than through the factory's email sequence:
      # the sequence restarts per process, so a suite run alongside another one
      # collides on the unique email index and blocks rather than failing usefully.
      twelve = Array.new(12) do
        User.create!(email: "member-#{SecureRandom.hex(6)}@example.test",
                     password: "password", confirmed_at: Time.current)
      end

      expect { twelve.each { |user| Membership.create!(account: account, user: user) } }
        .to change { account.memberships.count }.by(12)
    end
  end

  describe "on a self-hosted install" do
    before { allow(Tastatur).to receive(:self_hosted?).and_return(true) }

    # The account row is not rewritten when an instance switches to self-hosted, so
    # an account created before the switch still says "free". Routing every limit
    # through `billable?` is what stops that account being capped on hardware its
    # owner is paying for.
    it "ignores the stored plan and applies no limits" do
      account = create(:account, plan: "free")

      expect(account.billing_plan).to eq(Billing::Plan::SELF_HOSTED)
      expect(account.event_limit).to eq(Billing::Plan::UNLIMITED)
      expect(account.site_limit).to eq(Billing::Plan::UNLIMITED)
      expect(account.at_site_limit?).to be(false)
      expect(account.can_upgrade?).to be(false)
    end

    # The overrides are a hosted-service support lever. A value left in the column by
    # an import or by an earlier deployment must not be able to throttle an instance
    # somebody is running on their own hardware — and Billing::EventQuota ignores it
    # too, so this is what stops the model reporting a limit that enforcement does
    # not apply.
    it "ignores a limit override left in the columns" do
      account = create(:account, plan: "free", event_limit_override: 10, site_limit_override: 1)

      expect(account.event_limit).to eq(Billing::Plan::UNLIMITED)
      expect(account.site_limit).to eq(Billing::Plan::UNLIMITED)
    end
  end

  describe "#at_site_limit? and #sites_remaining" do
    it "counts against the resolved limit" do
      account = create(:account, plan: "free")

      expect(account.at_site_limit?).to be(false)
      expect(account.sites_remaining).to eq(1)

      create(:site, account: account)

      expect(account.reload.at_site_limit?).to be(true)
      expect(account.sites_remaining).to eq(0)
    end

    # A cancelled Pro account keeps all twenty of its sites, so "remaining" is
    # legitimately negative. Reported honestly rather than clamped, so nothing can
    # tell somebody nineteen over that they have one site left.
    it "goes negative for an account left over its limit by a downgrade" do
      account = create(:account, plan: "free", site_limit_override: 4)
      4.times { create(:site, account: account) }
      account.update!(site_limit_override: nil)

      expect(account.reload.sites_remaining).to eq(-3)
      expect(account.at_site_limit?).to be(true)
    end

    it "is unlimited when the plan is" do
      expect(create(:account, plan: "self_hosted").sites_remaining).to eq(Billing::Plan::UNLIMITED)
    end
  end

  describe "subscription state" do
    it "reports good standing only for the statuses that mean paid up" do
      %w[active trialing].each do |status|
        expect(build(:account, subscription_status: status)).to be_subscription_in_good_standing
      end

      %w[past_due unpaid canceled incomplete incomplete_expired paused].each do |status|
        expect(build(:account, subscription_status: status)).not_to be_subscription_in_good_standing
      end
    end

    # An unrecognised future status must read as "not confirmed good" rather than
    # quietly passing, which is why the model lists what counts as good instead of
    # what counts as bad.
    it "treats a status it has never heard of as not in good standing" do
      expect(build(:account, subscription_status: "some_future_status"))
        .not_to be_subscription_in_good_standing
    end

    it "flags a card that needs attention without deciding entitlement" do
      expect(build(:account, subscription_status: "past_due")).to be_payment_problem
      expect(build(:account, subscription_status: "unpaid")).to be_payment_problem
      expect(build(:account, subscription_status: "active")).not_to be_payment_problem
    end

    it "is only cancelling when there is a subscription to cancel" do
      expect(build(:account, cancel_at_period_end: true, stripe_subscription_id: nil)).not_to be_cancelling
      expect(build(:account, cancel_at_period_end: true, stripe_subscription_id: "sub_1")).to be_cancelling
      expect(build(:account, cancel_at_period_end: false, stripe_subscription_id: "sub_1")).not_to be_cancelling
    end

    it "offers an upgrade only from an unpaid plan on a billable instance" do
      expect(create(:account, plan: "free").can_upgrade?).to be(true)
      expect(create(:account, plan: "pro").can_upgrade?).to be(false)
    end
  end

  # THE GUARD, in the shape of spec/jobs/queue_names_spec.rb.
  #
  # A plan key is now written in three places: the catalogue, the model's
  # validation list, and a CHECK constraint in the database. Nothing else compares
  # them, so adding a plan to the catalogue and forgetting the migration produces a
  # write that passes validation and is rejected by PostgreSQL — in production
  # only, inside a webhook handler, where the account is then left on whatever it
  # was.
  describe "the plan vocabulary" do
    let(:constraint) do
      ActiveRecord::Base.connection.select_value(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'accounts_plan_check'"
      )
    end

    it "is defined once, in the catalogue" do
      expect(Account::PLANS).to eq(Billing::Plan::KEYS)
      expect(Account::PLANS).to eq(%w[free pro self_hosted])
    end

    it "agrees with the database constraint in both directions" do
      expect(constraint).to be_present, "accounts_plan_check is missing from the database"

      Account::PLANS.each { |key| expect(constraint).to include("'#{key}'") }

      quoted = constraint.scan(/'([a-z_]+)'/).flatten
      expect(quoted.sort).to eq(Account::PLANS.sort)
    end

    # The validation is not the guarantee. A webhook handler writing a plan with
    # update_column, or any path that skips validations, has to be stopped by the
    # database or it leaves a row that Billing::Plan.find! then raises on every
    # time the billing screen is opened.
    it "is enforced by the database, not only by the validation" do
      account = create(:account, plan: "free")

      expect { account.update_column(:plan, "growth") }
        .to raise_error(ActiveRecord::StatementInvalid, /accounts_plan_check/)
    end

    it "resolves every key it allows to a catalogue entry" do
      Account::PLANS.each { |key| expect(Billing::Plan.find!(key).key).to eq(key) }

      expect { Billing::Plan.find!("growth") }.to raise_error(ArgumentError, /unknown plan/)
    end
  end
end
