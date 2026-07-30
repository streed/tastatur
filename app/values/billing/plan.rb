module Billing
  # What a plan allows, what it costs, and which Stripe price sells it.
  #
  # THE CATALOGUE IS CODE, NOT A DATABASE TABLE. There are three plans and they
  # change about once a year. A `plans` table would buy the ability to edit
  # limits without a deploy, at the cost of every environment being able to
  # disagree about what "free" means — including the test suite, which would
  # then assert against whatever a fixture happened to say rather than against
  # the offer we actually make. The account row stores only the plan *key*;
  # everything else is looked up here.
  #
  # Stripe owns the amount a customer is charged; this file owns what they are
  # allowed. The two are connected by one string per paid plan — the price id in
  # `STRIPE_PRICE_PRO` — and `rails tastatur:billing:verify` checks that the
  # amount on that price still matches `price_cents` below, so a price edited in
  # the Stripe dashboard cannot silently contradict /pricing.
  class Plan < Dry::Struct
    # Limits are integers, except when they are not limits at all. Float::INFINITY
    # rather than nil so every call site can just compare — `used < limit` reads
    # the same whether or not a ceiling exists, and there is no third branch for
    # somebody to forget.
    UNLIMITED = Float::INFINITY

    Quota = Types::Strict::Integer | Types::Strict::Float

    attribute :key, Types::Strict::String
    attribute :name, Types::Strict::String
    attribute :price_cents, Types::Strict::Integer
    attribute :currency, Types::Strict::String

    # Events we will record for this account in a calendar month. Events beyond
    # it are refused at ingest — see Billing::UsageMeter for what that means and
    # what the site owner is shown.
    attribute :monthly_event_limit, Quota

    # Sites the account may have. Enforced when a site is created and NEVER by
    # deleting one: a downgrade is a billing event, and billing events do not
    # destroy customer data. See Site#account_within_site_limit.
    attribute :site_limit, Quota

    # Whether this plan can be bought. `free` cannot, because you get it by
    # signing up; `self_hosted` cannot, because that deployment has no billing.
    attribute :purchasable, Types::Strict::Bool

    # Teammates are unlimited on every plan, deliberately, which is why this is a
    # constant and not an attribute. Per-seat pricing on an analytics tool means
    # the person who most needs to see the numbers is the person nobody wants to
    # pay for, and the shared login that follows is worse for everyone including
    # us. spec/models/account_spec.rb asserts it, so removing the constant is not
    # enough to quietly introduce a seat cap.
    MEMBER_LIMIT = UNLIMITED

    # --- The catalogue -------------------------------------------------------

    FREE = new(
      key: "free",
      name: "Free",
      price_cents: 0,
      currency: "usd",
      monthly_event_limit: 500_000,
      site_limit: 1,
      purchasable: false
    )

    PRO = new(
      key: "pro",
      name: "Pro",
      price_cents: 3_000,
      currency: "usd",
      monthly_event_limit: 10_000_000,
      site_limit: 20,
      purchasable: true
    )

    # Not an offer. This is what an account looks like on an install someone runs
    # on their own hardware, where a paywall would be absurd.
    SELF_HOSTED = new(
      key: "self_hosted",
      name: "Self-hosted",
      price_cents: 0,
      currency: "usd",
      monthly_event_limit: UNLIMITED,
      site_limit: UNLIMITED,
      purchasable: false
    )

    ALL = [ FREE, PRO, SELF_HOSTED ].freeze
    KEYS = ALL.map(&:key).freeze

    # What /pricing shows, in the order it shows them.
    OFFERED = [ FREE, PRO ].freeze

    class << self
      def find(key)
        ALL.find { |plan| plan.key == key.to_s }
      end

      # Raises rather than returning nil. A plan key that is not in the catalogue
      # means the database holds a value this code has never heard of, and
      # guessing "probably free" would either give away a paid plan or take one
      # away. Both are worse than an exception with the key in it.
      def find!(key)
        find(key) || raise(ArgumentError, "unknown plan #{key.inspect}; known plans are #{KEYS.join(', ')}")
      end

      def free = FREE
      def pro = PRO
      def self_hosted = SELF_HOSTED

      # Every plan that can be bought. Used by Billing::SyncSubscription to decide
      # what an unrecognised Stripe price should fall back to: with exactly one
      # purchasable plan the answer is unambiguous, and with more than one it is a
      # guess that must not be made.
      def purchasable_plans = ALL.select(&:purchasable)

      # The plan a brand-new account starts on, which differs by deployment.
      def default
        Tastatur.self_hosted? ? SELF_HOSTED : FREE
      end

      # Turns a Stripe price id back into a plan. Built on each call rather than
      # memoised into a hash: the price ids come from the environment, and a
      # memoised lookup would be fixed at boot and stay wrong for the life of the
      # process if it were ever reconfigured.
      def for_stripe_price(price_id)
        return nil if price_id.blank?

        ALL.find { |plan| plan.stripe_price_id == price_id }
      end
    end

    # --- Instance ------------------------------------------------------------

    # `STRIPE_PRICE_PRO`. Read at call time, not at load time, so a spec can set
    # it, and so a missing one fails loudly at checkout with a message naming the
    # variable rather than as a nil quietly baked into a constant at boot.
    def stripe_price_id
      return nil unless purchasable

      ENV["STRIPE_PRICE_#{key.upcase}"].presence
    end

    def stripe_price_env_var = "STRIPE_PRICE_#{key.upcase}"

    def configured? = !purchasable || stripe_price_id.present?

    def free? = price_cents.zero?
    def paid? = price_cents.positive?

    def unlimited_events? = monthly_event_limit == UNLIMITED
    def unlimited_sites? = site_limit == UNLIMITED

    # 3000 -> "30". Whole dollars, because both published prices are whole
    # dollars and "$30.00" on a pricing page reads like a form field.
    def price_display
      return "0" if price_cents.zero?
      return (price_cents / 100).to_s if (price_cents % 100).zero?

      format("%.2f", price_cents / 100.0)
    end

    def to_param = key
  end
end
