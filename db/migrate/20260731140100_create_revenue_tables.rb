# The revenue half of the product: which acquisition source produced paying
# customers, rather than which produced traffic.
#
# THESE TABLES ARE NOT ANONYMOUS, AND THAT IS THE DESIGN — so it needs saying
# plainly, next to the columns, rather than being discovered later by somebody
# reading §13 and concluding this is a violation.
#
# Everything in `events` is anonymous by construction: the identifier is a salted
# hash whose salt is destroyed nightly, and nobody, including us, can rejoin two
# days of it. That property is what lets the tracker run with no consent banner.
#
# `customers` is fed by a completely different pipe. It is written only by
# `/api/v1/identify` and by Stripe webhooks — both server-to-server, both
# authenticated, both carrying data the customer's own application already holds
# about a person who has signed up for it. The legal basis is theirs and already
# exists; we are a processor for it. No browser session is ever load-bearing here,
# which is the point: a closed tab, a rotated salt or a payment completed on a
# different device cannot lose a financial fact.
#
# THE TWO PIPES MEET ONLY ON KEYS THE CUSTOMER SUPPLIES — `external_id` and
# `stripe_customer_id` — never on `visitor_hash`. There is deliberately no column
# joining a Customer to a visitor. Adding one would make the anonymous side
# retroactively identifiable and would break the claim on /privacy that the
# hashes stop working after 24 hours. See docs/architecture/revenue.md.
class CreateRevenueTables < ActiveRecord::Migration[8.1]
  def change
    create_customers
    create_stripe_connections
    create_connect_events
    create_customer_subscriptions
    create_revenue_events
  end

  private

  # A person the customer's application has told us about, plus where they came
  # from. One row per identified person per site.
  def create_customers
    create_table :customers do |t|
      t.references :site, null: false, foreign_key: true

      # The customer's own primary key for this person, as a string. Whatever
      # `current_user.id` is in their application.
      t.string :external_id

      # Set by identify() or discovered from a Stripe webhook, whichever happens
      # first. This is the join between the two ingestion paths.
      t.string :stripe_customer_id

      # SHA-256 of the lowercased, trimmed address, and a LAST-RESORT join key for
      # a Stripe customer that arrived with no metadata — a subscription created
      # in the Stripe dashboard by hand, or a checkout that predates the SDK.
      #
      # Hashed rather than stored, because an address is the one identifier here
      # that is directly personal and is useful to an attacker on its own. Hashing
      # keeps it usable for the equality join that is the only thing we do with
      # it, and useless for anything else. There is no salt on purpose: a
      # per-site salt would make the join impossible, which is the whole reason
      # the column exists.
      t.string :email_hash, limit: 64

      # --- First touch, written once ----------------------------------------
      #
      # WRITE-ONCE IS ENFORCED IN Revenue::IdentifyCustomer, not here, because
      # "first wins" is not expressible as a column constraint. The spec pins it.
      #
      # First-touch is a decision, not a default: it is the model that answers
      # "which channel should I spend more on", it is explicable in one sentence,
      # and it does not change retroactively when somebody returns via a Google
      # search for the brand name they already knew. Configurable attribution
      # models are a support burden and a trust sink — a number that moves because
      # a dropdown moved is a number nobody believes.
      t.string :attribution_source
      t.string :attribution_medium
      t.string :attribution_campaign
      t.string :attribution_content
      t.string :attribution_term
      t.string :attribution_landing_path
      t.string :attribution_referrer_host

      # When this person first arrived, as reported by the customer's app from
      # `tastatur.attribution()`. NOT when we first heard about them — those differ
      # by however long the signup funnel takes, and the whole point is to credit
      # the visit rather than the signup.
      t.datetime :first_seen_at

      t.datetime :identified_at
      t.datetime :converted_at
      t.datetime :churned_at

      # Denormalised from customer_subscriptions and revenue_events respectively,
      # because the customers screen sorts and pages on both and neither is
      # derivable without a join per row. Recomputed by
      # Revenue::RecalculateCustomer, which is the only writer.
      t.integer :current_mrr_cents, null: false, default: 0
      t.bigint  :lifetime_revenue_cents, null: false, default: 0

      t.uuid :public_id, default: -> { "gen_random_uuid()" }, null: false

      t.timestamps
    end

    add_index :customers, :public_id, unique: true

    # PARTIAL uniqueness on both join keys. A customer can legitimately have
    # neither yet — a row created from a Stripe event that carried only an email
    # — and `NULL` is distinct from `NULL` in a plain unique index, so without the
    # `WHERE` clause the first two such rows would be fine and the constraint
    # would be silently unenforced for exactly the rows it matters for.
    add_index :customers, %i[site_id stripe_customer_id],
              unique: true, where: "stripe_customer_id IS NOT NULL"
    add_index :customers, %i[site_id external_id],
              unique: true, where: "external_id IS NOT NULL"

    # NOT unique. Two people can share an address across two of the customer's own
    # accounts, and refusing the second would lose a real paying customer to
    # protect a fallback join. Revenue::MatchCustomer treats an ambiguous email
    # match as no match at all.
    add_index :customers, %i[site_id email_hash], where: "email_hash IS NOT NULL"

    # The attribution rollup groups by these three, for one site, over a date
    # range. Without this it is a sequential scan of every customer the site has.
    add_index :customers, %i[site_id attribution_source attribution_medium attribution_campaign],
              name: "idx_customers_attribution"
  end

  # One connected Stripe account per site.
  #
  # NO ACCESS TOKEN IS STORED, and that is worth reading twice, because the
  # obvious implementation stores one and the spec this was built from says to.
  #
  # Stripe accepts either the connected account's OAuth access token, or the
  # PLATFORM's own secret key plus a `Stripe-Account: acct_...` header. Both reach
  # exactly the same data. The second needs no long-lived third-party credential
  # on our disk — so there is nothing here to encrypt, nothing to rotate, nothing
  # to leak in a database backup, and no dependency on ActiveRecord encryption
  # being configured in every deployment (it is not configured in any of them).
  #
  # The OAuth round trip still happens: it is how the customer grants access and
  # how we learn the account id. We simply throw the token away at the end of it.
  # `Revenue::StripeAccount.call` is the one place that builds the per-request
  # options, so there is one answer to "how do we talk to a connected account".
  def create_stripe_connections
    create_table :stripe_connections do |t|
      t.references :site, null: false, foreign_key: true

      t.string :stripe_account_id, null: false

      # Which set of books this is. A test-mode connection reporting into the
      # revenue screen next to live figures is the kind of error that gets acted
      # on before it gets noticed.
      t.boolean :livemode, null: false, default: true

      # What Stripe actually granted, recorded rather than assumed. We ask for
      # `read_only`; storing the answer means a connection that somehow carries
      # write scope is visible instead of implicit.
      t.string :scope, null: false, default: "read_only"

      t.datetime :connected_at, null: false
      t.datetime :backfilled_at
      t.datetime :revoked_at

      t.uuid :public_id, default: -> { "gen_random_uuid()" }, null: false

      t.timestamps
    end

    add_index :stripe_connections, :public_id, unique: true

    # One LIVE connection per site, and one per Stripe account globally.
    #
    # Partial on `revoked_at IS NULL` so a site can disconnect and reconnect —
    # and so the same Stripe account can be moved between sites — without the
    # history being deleted to make room. The revoked rows are what answer "when
    # did revenue stop arriving, and did somebody disconnect it?"
    add_index :stripe_connections, :site_id,
              unique: true, where: "revoked_at IS NULL",
              name: "idx_stripe_connections_live_per_site"
    add_index :stripe_connections, :stripe_account_id,
              unique: true, where: "revoked_at IS NULL",
              name: "idx_stripe_connections_live_per_account"
  end

  # Inbound Stripe Connect deliveries, stored before they are interpreted.
  #
  # DELIBERATELY NOT `ProcessedWebhookEvent`, which already exists and does the
  # same job for OUR OWN billing. Two reasons, and the first is enough: that table
  # records an id and nothing else, because our own webhooks are re-fetchable at
  # any time from our own Stripe account. These are not — if the customer
  # disconnects, the account we would re-fetch from is gone, and an event we
  # failed to process is unrecoverable. So the payload is kept.
  #
  # The second is tenancy. `processed_webhook_events` is instance-wide; every row
  # here belongs to exactly one site and must be deletable with it.
  def create_connect_events
    create_table :connect_events do |t|
      t.references :site, null: false, foreign_key: true

      t.string :stripe_event_id, null: false
      t.string :event_type, null: false
      t.jsonb  :payload, null: false

      # From the event, not from our clock. Stripe retries for three days, so
      # `created_at` here can be far from when the thing actually happened, and
      # every revenue figure is bucketed by when it happened.
      t.datetime :occurred_at, null: false

      # NULL means "received, not yet applied". THE RECEIPT IS `processed_at`,
      # NOT the row's existence — the same rule §14 states for
      # ProcessedWebhookEvent, and for the same reason: a row written on arrival
      # and treated as a receipt would make Stripe's retry look like a duplicate
      # and discard the work silently.
      t.datetime :processed_at

      # The last failure, kept so a stuck event is diagnosable from the database
      # rather than only from a log that has rotated.
      t.text :error

      t.timestamps
    end

    add_index :connect_events, %i[site_id stripe_event_id], unique: true

    # The retry sweep's query: everything that arrived and never applied.
    add_index :connect_events, %i[site_id occurred_at],
              where: "processed_at IS NULL",
              name: "idx_connect_events_unprocessed"
  end

  # A subscription in the CUSTOMER'S Stripe account.
  #
  # NAMED `customer_subscriptions`, NOT `subscriptions`, and the extra word is
  # load-bearing. This codebase already tracks a subscription: the one an Account
  # holds to Tastatur, on `accounts.stripe_subscription_id`, synced by
  # Billing::SyncSubscription. Those are our revenue. These are our customer's
  # revenue. A bare `Subscription` model sitting next to `Billing::` code that
  # means the opposite thing is a mistake somebody makes exactly once, at 2am,
  # in a service that writes to the wrong one.
  def create_customer_subscriptions
    create_table :customer_subscriptions do |t|
      t.references :site, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true

      t.string :stripe_subscription_id, null: false
      t.string :status, null: false

      # Normalised to a month by Revenue::MonthlyValue regardless of the billing
      # interval, so an annual plan and a monthly one are comparable. Integer
      # cents; there is no float anywhere in this pipeline.
      t.integer :mrr_cents, null: false, default: 0
      t.string  :currency, null: false

      t.datetime :started_at
      t.datetime :trial_ends_at
      t.datetime :canceled_at

      # THE ORDERING GUARD. Stripe does not guarantee delivery order, and a
      # `customer.subscription.updated` from a cancellation and one from an
      # upgrade can arrive in either order. Applying the older one last leaves the
      # row permanently wrong with nothing to correct it — and unlike
      # Billing::SyncSubscription, this pipeline cannot simply re-fetch its way
      # out of the problem, because re-fetching every subscription on every
      # delivery would mean an API call per webhook against a customer's rate
      # limit rather than our own.
      #
      # So the event's own timestamp is stored and an older one is dropped.
      t.datetime :last_event_at, null: false

      t.uuid :public_id, default: -> { "gen_random_uuid()" }, null: false

      t.timestamps
    end

    add_index :customer_subscriptions, :public_id, unique: true
    add_index :customer_subscriptions, %i[site_id stripe_subscription_id], unique: true
    add_index :customer_subscriptions, :customer_id, name: "idx_customer_subscriptions_customer"
  end

  # What actually happened to money, as a ledger.
  #
  # A LEDGER RATHER THAN A CURRENT-STATE TABLE, because every question the
  # attribution screen asks is about a period: new MRR in March, churn last week.
  # Those are not answerable from a subscription's present status — a customer who
  # signed up and cancelled inside the month is invisible in current state and is
  # exactly the row a marketer needs to see against the campaign that bought them.
  def create_revenue_events
    create_table :revenue_events do |t|
      t.references :site, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true

      t.string :kind, null: false

      # SIGNED. A churn is negative, a refund is negative. Storing magnitudes plus
      # a direction implied by `kind` means every consumer has to re-derive the
      # sign from a string, and one of them eventually gets it wrong and reports
      # churn as growth.
      t.integer :amount_cents, null: false
      t.string  :currency, null: false

      # `amount_cents` converted to the site's base currency at the rate on
      # `occurred_at`. NULL when no rate was available, which is deliberately
      # distinguishable from zero: a report that silently treats an unconvertible
      # €40 as £0 is worse than one that says it could not convert it.
      t.integer :normalized_cents

      # How this changed recurring revenue, which is NOT the same number as the
      # amount. A yearly invoice of $480 is $40 of MRR; a one-off charge is
      # revenue with no MRR delta at all.
      t.integer :mrr_delta_cents

      # The Stripe object this came from — an invoice, a charge, a subscription.
      # Paired with `kind` it is what makes replaying a webhook idempotent.
      t.string :stripe_object_id

      t.datetime :occurred_at, null: false

      t.timestamps
    end

    # The rollup's range scan.
    add_index :revenue_events, %i[site_id occurred_at]
    add_index :revenue_events, %i[customer_id occurred_at],
              name: "idx_revenue_events_customer_time"

    # IDEMPOTENCY, ENFORCED BY THE DATABASE.
    #
    # Stripe retries, our own backfill overlaps live webhooks by design, and the
    # unprocessed-event sweep re-runs anything that failed halfway. Every one of
    # those can present the same financial fact twice. A Ruby-side `find_or_create`
    # loses that race under concurrent delivery — and the visible symptom is a
    # customer's MRR doubling, which reads as a great month rather than as a bug.
    #
    # Partial, because a hand-written adjustment has no Stripe object and several
    # of those are legitimate on one day.
    add_index :revenue_events, %i[site_id stripe_object_id kind],
              unique: true, where: "stripe_object_id IS NOT NULL",
              name: "idx_revenue_events_idempotent"

    # TWO FAMILIES OF KIND LIVE IN THIS ONE COLUMN, and the distinction is the
    # thing most easily got wrong in a revenue schema.
    #
    #   new, expansion, contraction, churn, reactivation
    #       describe a change to RECURRING revenue. `amount_cents` is an MRR
    #       delta — what will be collected every month from now on.
    #
    #   payment, one_time, refund, dispute
    #       describe CASH that actually moved. `amount_cents` is the amount on
    #       the invoice or charge.
    #
    # They are never summed together. An annual subscription writes a `new` of
    # 4,000 (its monthly worth) and a `payment` of 48,000 (what was charged); add
    # those and the customer appears to have paid 52,000, which is not a number
    # that exists. RevenueEvent::MRR_KINDS and CASH_KINDS are the two lists, and
    # every consumer reads one or the other and never `.all`.
    add_check_constraint :revenue_events,
                         "kind IN ('new', 'expansion', 'contraction', 'churn', 'reactivation', " \
                         "'payment', 'refund', 'dispute', 'one_time')",
                         name: "revenue_events_kind_check"

    add_check_constraint :revenue_events, "currency ~ '^[A-Z]{3}$'",
                         name: "revenue_events_currency_check"
  end
end
