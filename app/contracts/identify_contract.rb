# Validates a POST /api/v1/identify body before any of it reaches a service.
#
# DECLARED KEYS ARE THE POINT, exactly as in StripeEventContract: dry-schema
# returns only what is declared, so Revenue::IdentifyCustomer receives a plain
# symbol-keyed Hash and a field nobody declared cannot quietly become
# load-bearing. A customer's app posting its entire user object at this endpoint
# — which is the obvious thing to do, and which people will do — must not result
# in us storing their entire user object.
class IdentifyContract < Dry::Validation::Contract
  params do
    # At least one of these three has to be present; `rule` below enforces that,
    # because dry-schema has no "any of" at the params level.
    optional(:external_id).maybe(:string)
    optional(:stripe_customer_id).maybe(:string)

    # Hashed on receipt and never stored. Declared as a plain string rather than
    # with a format check — an address we cannot parse is still an address we can
    # hash, and refusing it would break the join for a real customer over a
    # regex disagreement.
    optional(:email).maybe(:string)

    optional(:attribution).hash do
      optional(:source).maybe(:string)
      optional(:medium).maybe(:string)
      optional(:campaign).maybe(:string)
      optional(:content).maybe(:string)
      optional(:term).maybe(:string)
      optional(:landing_path).maybe(:string)
      optional(:referrer_host).maybe(:string)

      # ISO 8601 from the customer's app. Coerced here so the service never sees
      # a string, and `maybe` so an app that has not stored one yet is not
      # refused outright — attribution with no timestamp is still attribution.
      optional(:first_seen_at).maybe(:time)
    end
  end

  # A row with none of the three identifiers is unreachable forever — it can never
  # be matched to a Stripe customer, and it can never be updated by a later
  # identify call. Customer validates the same thing at the model level; catching
  # it here is what turns it into a 422 with an explanation instead of a 500.
  rule(:external_id, :stripe_customer_id, :email) do
    if values[:external_id].blank? && values[:stripe_customer_id].blank? && values[:email].blank?
      key(:external_id).failure("one of external_id, stripe_customer_id or email is required")
    end
  end
end
