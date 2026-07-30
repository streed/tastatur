# Validates a Stripe webhook envelope before any of it reaches a service.
#
# The signature check proves Stripe sent the request. It says nothing about what
# is inside, and the fields a handler needs differ by event type: a checkout
# session carries `subscription` and `client_reference_id`, a subscription carries
# `status` and `items`, an invoice carries neither. So this contract guarantees the
# three things every handler relies on — an event id, a type, and an object with
# an id — and declares the optional fields the handlers actually read.
#
# DECLARED KEYS ARE THE POINT. dry-schema returns only what is declared, so
# Billing::ApplyStripeEvent receives a plain symbol-keyed Hash containing nothing
# else. That keeps the service free of Stripe object semantics (`[]` returning nil
# for absent fields, readers that raise for fields the pinned API version has
# moved), makes it trivially specifiable from a literal hash, and means a field
# nobody declared cannot quietly become load-bearing.
class StripeEventContract < Dry::Validation::Contract
  params do
    required(:id).filled(:string)
    required(:type).filled(:string)
    optional(:created).maybe(:integer)

    required(:data).hash do
      required(:object).hash do
        required(:id).filled(:string)
        optional(:object).maybe(:string)

        # An id string by default, a nested hash when expanded. Left untyped so
        # both pass; Billing::SyncSubscription normalises it.
        optional(:customer)

        # Present on a checkout session: the subscription it created.
        optional(:subscription)

        optional(:status).maybe(:string)
        optional(:client_reference_id).maybe(:string)
        optional(:metadata).hash
      end
    end
  end
end
