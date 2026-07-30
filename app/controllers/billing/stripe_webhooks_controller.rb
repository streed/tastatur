module Billing
  # Stripe's callback.
  #
  # INHERITS ActionController::API, and that is a security decision rather than a
  # style one. Rails' forgery protection runs as a before_action on
  # ActionController::Base and would reject every webhook, which is normally
  # escaped with `skip_forgery_protection` — but the test environment sets
  # `allow_forgery_protection = false`, so a controller that forgot the skip would
  # pass every request spec and fail only in production. An API controller has no
  # forgery protection to forget. The same inheritance is what keeps
  # `authenticate_user!`, Pundit's `verify_authorized` and the first-run redirect
  # off this path, exactly as it does for the ingest endpoint.
  #
  # It reads NO client address, and must not start. spec/privacy_invariants_spec.rb
  # holds an exact-equality list of the only two files allowed to take the caller's
  # address off the request, and this is not one of them — the list is a text scan,
  # so even naming the method in a comment here fails it, deliberately. The
  # signature header is what authenticates a request; an address allowlist would be
  # weaker and one more thing to keep current as Stripe's ranges change.
  #
  # It is also exempt from Rack::Attack's per-client throttle. Stripe delivers from
  # a small fixed set of addresses, so every customer's events share one throttle
  # key — see the note in config/initializers/rack_attack.rb.
  class StripeWebhooksController < ActionController::API
    # ApplicationController includes this for every other controller so none of
    # them can forget; an API controller does not inherit from it, and pattern
    # matching a service result without the constants in scope fails at runtime
    # with "uninitialized constant Success".
    include Dry::Monads[:result]

    def create
      # Nothing to bill on a self-hosted install, so there is nothing here. 404
      # rather than 403: the endpoint genuinely does not exist in that deployment.
      return head :not_found if Tastatur.self_hosted?
      return refuse_unconfigured if webhook_secret.blank?

      event = Stripe::Webhook.construct_event(request.raw_post, signature_header, webhook_secret)

      validated = StripeEventContract.new.call(event.to_hash)
      if validated.failure?
        Rails.logger.error("[tastatur] stripe webhook failed validation: #{validated.errors.to_h}")
        return head :bad_request
      end

      respond_to_result(Billing::ApplyStripeEvent.call(event: validated.to_h))
    rescue Stripe::SignatureVerificationError => e
      # Expected traffic on a public endpoint, not an incident: anything on the
      # internet can POST here. Logged at info so a genuine misconfiguration is
      # findable, and deliberately not sent to Sentry.
      Rails.logger.info("[tastatur] rejected an unsigned stripe webhook: #{e.message}")
      head :bad_request
    rescue JSON::ParserError => e
      # A validly-signed body that is not JSON. construct_event raises this rather
      # than a StripeError, so rescuing only StripeError would leave a 500 here.
      Rails.logger.error("[tastatur] stripe webhook body was not JSON: #{e.message}")
      head :bad_request
    end

    private

    # WHAT STRIPE DOES WITH EACH STATUS is the entire point of this method.
    # A non-2xx is a failed delivery: Stripe retries with backoff for three days
    # and disables the endpoint if it keeps failing. So 2xx means "do not send this
    # again", and it is the right answer even for events we cannot use — an event
    # for an account we do not have will never become one we do.
    def respond_to_result(result)
      case result
      in Success(_)
        head :ok
      in Failure(stripe_error: message)
        # Our side could not reach Stripe. A retry is exactly what is wanted.
        Rails.logger.error("[tastatur] stripe webhook could not be applied: #{message}")
        head :service_unavailable
      in Failure(:duplicate)
        head :ok
      in Failure(:unknown_account)
        Rails.logger.warn("[tastatur] stripe webhook matched no account")
        head :ok
      in Failure(_)
        head :ok
      end
    end

    def signature_header
      request.headers["Stripe-Signature"]
    end

    def webhook_secret
      Rails.configuration.stripe[:webhook_secret]
    end

    # Without the signing secret nothing here can be trusted, so nothing is
    # processed. 503 rather than 400 because the fault is ours and a retry after
    # the secret is set will succeed — which turns a misconfigured deploy into a
    # short gap rather than lost subscription events.
    def refuse_unconfigured
      message = "[tastatur] STRIPE_WEBHOOK_SECRET is not set — refusing to trust a webhook. " \
                "Subscription changes will not be applied until it is."
      Rails.logger.error(message)
      Sentry.capture_message(message) if defined?(Sentry)

      head :service_unavailable
    end
  end
end
