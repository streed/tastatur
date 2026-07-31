module Revenue
  # Stripe Connect deliveries: events about our CUSTOMERS' Stripe accounts.
  #
  # A SEPARATE ENDPOINT FROM Billing::StripeWebhooksController, WITH ITS OWN
  # SIGNING SECRET, and merging them is not an available shortcut. In the Stripe
  # dashboard a webhook endpoint is either "account" or "connect"; one endpoint
  # cannot be both, and each carries a distinct signing secret. Pointing Connect
  # deliveries at the billing endpoint would fail every signature check — and
  # because that controller answers 400 on a bad signature, Stripe would disable
  # it after three days of failures, taking our own subscription billing down as
  # collateral.
  #
  # INHERITS ActionController::API for the reasons the billing webhook documents:
  # no forgery protection to forget, no session, no Pundit callbacks, and it reads
  # no client address (spec/privacy_invariants_spec.rb holds an exact-equality
  # list, and that list is a text scan — naming the method even in a comment fails
  # it, deliberately).
  #
  # STORE FIRST, INTERPRET LATER. The handler does the minimum: verify, persist,
  # enqueue, 200. Interpreting an event means several database writes and possibly
  # a Stripe round trip, and doing that inline puts Stripe's 300-second delivery
  # timeout in charge of our transaction boundary. Worse, a slow handler is
  # counted as a failure and retried, so the expensive work runs twice.
  class ConnectWebhooksController < ActionController::API
    include Dry::Monads[:result]

    def create
      # THE ORDER OF THESE TWO GUARDS IS THE WHOLE POINT, and the obvious order is
      # wrong. `Tastatur.revenue_enabled?` itself requires the signing secret — so
      # putting it first makes the 503 branch below structurally unreachable, and
      # a deployment that lost only its signing secret answers 404 to every
      # delivery. Stripe treats 404 as a permanent failure, so a misconfiguration
      # that a retry would have fixed instead discards the revenue silently. §14
      # records the same reasoning for the billing endpoint.
      #
      # `connect_client_id` is what distinguishes "configured and broken" from
      # "never set up here". An instance that intends to use Connect and has lost
      # its secret gets 503 and its deliveries retried; one that has no Connect
      # integration at all gets 404 for a stray POST, and nothing is logged,
      # because that is the correct configuration.
      return refuse_unconfigured if webhook_secret.blank? && connect_client_id.present?
      return head :not_found unless Tastatur.revenue_enabled?

      event = Stripe::Webhook.construct_event(request.raw_post, signature_header, webhook_secret)

      # An event type we do not handle needs no further thought and no storage.
      # 200 so Stripe does not send it again — Connect fans out a great deal, and
      # storing all of it would grow a customer's payload history without bound
      # for no benefit.
      return head :ok unless ConnectEvent::HANDLED.include?(event[:type].to_s)

      site = site_for(event[:account])
      # An event for an account nobody has connected, or has since disconnected.
      # 200: this will never become an account we have, so a retry is pointless,
      # and Stripe disables endpoints that keep failing.
      return head :ok if site.nil?

      store_and_enqueue(site, event)
    rescue Stripe::SignatureVerificationError => e
      # Expected traffic on a public endpoint rather than an incident — anything
      # on the internet can POST here. Logged at info so a genuine
      # misconfiguration is findable, and deliberately not sent to Sentry.
      Rails.logger.info("[tastatur] rejected an unsigned connect webhook: #{e.message}")
      head :bad_request
    rescue JSON::ParserError => e
      # A validly-signed body that is not JSON. `construct_event` raises this
      # rather than a StripeError, so rescuing only StripeError leaves a 500.
      Rails.logger.error("[tastatur] connect webhook body was not JSON: #{e.message}")
      head :bad_request
    end

    private

    # THE UNIQUE INDEX IS THE IDEMPOTENCY GUARANTEE, not the `exists?` check that
    # a reasonable person writes first. Stripe retries aggressively and delivers
    # concurrently; two workers can both see "no such row" and both insert. One
    # loses, and losing is fine — the event is already stored and already
    # enqueued, so answering 200 is correct.
    #
    # BOTH EXCEPTIONS ARE RESCUED, AND MISSING THE FIRST ONE IS THE BUG THAT
    # DISABLES THIS ENDPOINT. ConnectEvent also validates uniqueness in Ruby, so
    # the ordinary redelivery — the same event arriving twice, seconds apart —
    # fails the VALIDATION and raises RecordInvalid; the database constraint is
    # only reached in the genuine concurrent race. Rails maps an unhandled
    # RecordInvalid to 422, Stripe counts any non-2xx as a failed delivery, and
    # three days of "failures" that were really just retries of an event we had
    # already stored disables the endpoint — taking every customer's revenue
    # feed with it.
    def store_and_enqueue(site, event)
      record = site.connect_events.create!(
        stripe_event_id: event[:id],
        event_type: event[:type],
        payload: event.to_hash,
        occurred_at: Time.zone.at(event[:created].to_i)
      )

      ApplyConnectEventJob.perform_later(record.id)
      head :ok
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      head :ok
    end

    # Which site this event belongs to, resolved from the connected account id
    # Stripe puts on every Connect delivery.
    #
    # `live` only. A site that has disconnected must stop having its revenue
    # recorded immediately — that is what disconnecting means, and continuing to
    # write rows for a revoked connection because the row is still in the table
    # would make the button a lie.
    def site_for(stripe_account_id)
      return nil if stripe_account_id.blank?

      StripeConnection.live.find_by(stripe_account_id: stripe_account_id)&.site
    end

    def signature_header
      request.headers["Stripe-Signature"]
    end

    def webhook_secret
      Rails.configuration.stripe[:connect_webhook_secret]
    end

    def connect_client_id
      Rails.configuration.stripe[:connect_client_id]
    end

    # 503, not 404, for the same reason the billing endpoint does it: the fault is
    # ours and a retry after the secret is set will succeed, which turns a
    # misconfigured deploy into a short gap rather than permanently lost revenue
    # data. A 404 here would throw away both the diagnosis and the retry.
    def refuse_unconfigured
      message = "[tastatur] STRIPE_CONNECT_WEBHOOK_SECRET is not set — refusing to trust a Connect webhook. " \
                "Customer revenue will not be recorded until it is."
      Rails.logger.error(message)
      Sentry.capture_message(message) if defined?(Sentry)

      head :service_unavailable
    end
  end
end
