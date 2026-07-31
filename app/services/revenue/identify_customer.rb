module Revenue
  # Attaches a name, and a first touch, to somebody the customer's app knows about.
  #
  # THIS IS THE ONLY WRITE PATH FROM THE OUTSIDE WORLD INTO `customers`, and the
  # only place attribution is ever set from an application. Stripe can create a
  # customer row too, but it fills in money, not provenance.
  #
  # ATTRIBUTION IS WRITE-ONCE, AND THAT IS THE PRODUCT DECISION, not a caching
  # optimisation. First touch wins; a later identify call with different UTM
  # values is ignored, field by field.
  #
  # Why write-once rather than last-write-wins, which is what an ordinary upsert
  # would give: an application calls identify on every sign-in, not just at
  # signup. Under last-write-wins, a customer acquired from a Reddit post in
  # January who searches "acme login" in March is re-attributed to Google organic
  # — so every channel slowly loses its customers to whatever people type when
  # they already know the brand name, and the paid-acquisition numbers decay
  # towards zero on their own. That decay looks exactly like a campaign that
  # stopped working.
  #
  # Field-by-field rather than all-or-nothing, so an app that learns the landing
  # path later than the source can still fill in the gap without being able to
  # overwrite what is already there.
  class IdentifyCustomer < ApplicationService
    ATTRIBUTION_FIELDS = %i[
      attribution_source attribution_medium attribution_campaign
      attribution_content attribution_term attribution_landing_path
      attribution_referrer_host
    ].freeze

    def initialize(site:, params:, now: Time.current)
      @site = site
      @params = params
      @now = now
    end

    def call
      customer = find_or_create
      return customer if customer.is_a?(Dry::Monads::Result)

      apply_identifiers(customer)
      apply_attribution(customer)

      customer.identified_at ||= @now
      customer.save!

      Success(customer)
    rescue ActiveRecord::RecordInvalid => e
      Failure(invalid: e.record.errors.full_messages)
    end

    private

    def find_or_create
      existing = CustomerMatcher.call(site: @site, external_id: external_id,
                                      stripe_customer_id: stripe_customer_id,
                                      email_hash: email_hash)
      return existing if existing

      create_customer
    end

    # THE RACE THIS RESCUE EXISTS FOR IS REAL AND COMMON.
    #
    # A signup flow that calls identify from both a web request and a background
    # job — or a customer's app retrying a timed-out call — presents the same
    # external_id twice within milliseconds. Both `CustomerMatcher.call`s find
    # nothing, both insert, and the partial unique index refuses the second.
    #
    # Without this, that surfaces as a 500 on the customer's signup path, caused
    # by us, for a call that had already succeeded. Re-matching after the conflict
    # gets the row the winner created, which is the answer both callers wanted.
    def create_customer
      @site.customers.create!(
        external_id: external_id,
        stripe_customer_id: stripe_customer_id,
        email_hash: email_hash,
        first_seen_at: first_seen_at || @now,
        identified_at: @now
      )
    rescue ActiveRecord::RecordNotUnique
      CustomerMatcher.call(site: @site, external_id: external_id,
                           stripe_customer_id: stripe_customer_id,
                           email_hash: email_hash) ||
        Failure(:conflict)
    end

    # Identifiers FILL IN, they do not overwrite.
    #
    # An identify call carrying a Stripe id for a customer we only knew by
    # external id is exactly the join this whole feature depends on, so it must be
    # accepted. But a call carrying a DIFFERENT Stripe id for a customer that
    # already has one is either a bug in the caller or a person whose subscription
    # was recreated, and silently repointing the row would move all of their
    # historical revenue onto a stranger. Left alone and logged.
    def apply_identifiers(customer)
      assign_once(customer, :external_id, external_id)
      assign_once(customer, :stripe_customer_id, stripe_customer_id)
      assign_once(customer, :email_hash, email_hash)

      # first_seen_at moves EARLIER only. An app that reports a first touch older
      # than the one we hold has found better information — a returning visitor
      # whose original session predates the integration, most often — and that is
      # strictly more correct. Moving it later never is.
      if first_seen_at && (customer.first_seen_at.nil? || first_seen_at < customer.first_seen_at)
        customer.first_seen_at = first_seen_at
      end
    end

    def assign_once(customer, field, value)
      return if value.blank?

      current = customer.public_send(field)
      return customer.public_send("#{field}=", value) if current.blank?
      return if current == value

      Rails.logger.warn(
        "[tastatur] identify sent #{field}=#{value.inspect} for customer #{customer.public_id}, " \
        "which already holds #{current.inspect} — keeping the existing value"
      )
    end

    def apply_attribution(customer)
      attribution = normalized_attribution
      return if attribution.blank?

      ATTRIBUTION_FIELDS.each do |field|
        key = field.to_s.delete_prefix("attribution_").to_sym
        value = attribution[key]
        next if value.blank?

        next if attributed?(customer.public_send(field))

        customer.public_send("#{field}=", value)
      end
    end

    # THE WRITE-ONCE CHECK, and it turns on the difference between "we know" and
    # "we looked and there was nothing".
    #
    # `present?` alone is wrong in two ways. An empty string stored by an earlier
    # call would count as attributed and lock the field to "" forever — hence
    # `present?` rather than `nil?`.
    #
    # And `(pre-install)` is not an attribution at all. Revenue::BackfillStripe
    # writes it onto every customer imported from Stripe history, meaning
    # precisely "this person predates measurement and we have no idea where they
    # came from". Treating that as a first touch would make the backfill
    # permanently poison every customer it touched: the SDK gets installed the
    # following week, real attribution starts arriving for those same people, and
    # every one of them is pinned to "(pre-install)" forever. The import would
    # actively destroy the data it exists to make room for.
    #
    # So the sentinel is overwritable — exactly once, by the first real value.
    # After that, ordinary write-once applies and a later sign-in cannot re-attribute
    # anybody. This is the same reasoning that lets `first_seen_at` move earlier:
    # strictly better information is allowed to win, and nothing else is.
    def attributed?(value)
      value.present? && value != Channel::PRE_INSTALL
    end

    # The source is CLASSIFIED on the way in, so the stored value is already in
    # the events pipeline's vocabulary and the nightly rollup can group in SQL
    # without calling Ruby once per customer. `referrer_host` is passed so a
    # caller who supplies only a referrer still gets a source, exactly as
    # Ingest::Referrer does for the anonymous side.
    #
    # NO SENTINELS ARE WRITTEN. `Channel.resolve_source` returns nil rather than
    # "Direct" when there is nothing to classify, and medium and campaign are
    # passed through untouched — so a field the caller did not supply stays NULL.
    #
    # That distinction is not tidiness; it is the difference between working and
    # not. Attribution is write-once, so any sentinel stored here would make the
    # column non-blank and lock out the real value forever. The first version of
    # this method stored `Channel.normalize`'s output, which meant a first call
    # carrying only a source wrote "(none)" into the campaign — and every
    # customer was then permanently attributed to "(none)" for whatever their
    # first call omitted, while the report looked entirely plausible.
    def normalized_attribution
      raw = @params[:attribution] || {}
      return {} if raw.blank?

      source = Channel.resolve_source(raw[:source], raw[:referrer_host])
      source.present? ? raw.merge(source: source) : raw
    end

    def external_id = @params[:external_id].presence
    def stripe_customer_id = @params[:stripe_customer_id].presence
    def email_hash = @email_hash ||= Customer.hash_email(@params[:email])
    def first_seen_at = (@params[:attribution] || {})[:first_seen_at]
  end
end
