module Api
  module V1
    # POST /api/v1/identify — the handoff from the customer's application.
    #
    # This is the single most important request in the product, because it is the
    # only one that survives everything the anonymous pipeline cannot: a closed
    # tab, midnight salt rotation, an ad blocker, a payment completed three days
    # later on a different device. The browser's job is to tell the customer's app
    # where the visitor came from (`tastatur.attribution()`); the app's job is to
    # store that in its own user record, where it already has a legal basis for
    # holding data about that person; and this endpoint's job is to receive it
    # server-side when they sign up.
    #
    # That indirection is the whole cross-day attribution mechanism, and it is why
    # this product needs no cookie to do first-touch attribution.
    class IdentifyController < BaseController
      def create
        validated = IdentifyContract.new.call(body_params)
        return refuse_invalid(validated.errors) if validated.failure?

        case Revenue::IdentifyCustomer.call(site: site, params: validated.to_h)
        in Success(customer)
          render json: serialize(customer), status: :ok
        in Failure(invalid: messages)
          render json: { error: "invalid_request", message: messages.to_sentence },
                 status: :unprocessable_entity
        in Failure(:conflict)
          # Two concurrent identify calls for the same person, where the loser
          # could not then find the winner's row. Rare, transient, and a retry
          # succeeds — 409 rather than 500 says exactly that, and is the one status
          # a client library should retry on.
          render json: { error: "conflict", message: "That customer was being created concurrently. Retry." },
                 status: :conflict
        end
      end

      private

      # DELIBERATELY NARROW. This response goes to a caller who already knows
      # everything they sent us, so it exists to confirm the write and to hand back
      # the identifier they will need if they ever ask us about this person again.
      #
      # It does NOT echo the attribution. That sounds helpful and is a trap: the
      # obvious next thing a developer does with an echoed attribution is store it
      # back into their user record, which turns our write-once field into their
      # last-write-wins field and quietly destroys the guarantee the whole model
      # rests on. If they want it, `GET` it explicitly.
      def serialize(customer)
        {
          id: customer.public_id,
          external_id: customer.external_id,
          stripe_customer_id: customer.stripe_customer_id,
          identified_at: customer.identified_at&.iso8601,
          first_seen_at: customer.first_seen_at&.iso8601
        }
      end
    end
  end
end
