module Revenue
  # The Stripe Connect OAuth flow, both halves.
  #
  # Three of these actions are nested under a site and authenticated normally.
  # `callback` is not nested — Stripe matches redirect URIs exactly, so it has to
  # be one fixed path for the whole instance — and which site the callback belongs
  # to therefore has to travel in the `state` parameter and come back.
  class StripeConnectionsController < ApplicationController
    # Only the three nested actions get a site from the URL. `callback` derives
    # its site from the signed state instead, which is the entire security
    # question on that action.
    before_action :set_site, except: :callback
    before_action :ensure_revenue_enabled

    # Sends the customer to Stripe. A POST rather than a link so it carries CSRF
    # protection like any other state-changing action.
    def create
      authorize @site.stripe_connections.new, :create?

      # `state` IS A CSRF TOKEN AND A ROUTING SLIP AT THE SAME TIME, and both jobs
      # matter. Stripe echoes it back verbatim on the callback, so it is the only
      # thing telling us which site an authorization belongs to — and without the
      # random half, anyone could send a victim a crafted callback URL and attach
      # their own Stripe account to the victim's site.
      #
      # Held in the session rather than signed into the parameter, so it is
      # single-use by construction and cannot be replayed after the flow finishes.
      state = SecureRandom.urlsafe_base64(24)
      session[:stripe_connect] = { "state" => state, "site" => @site.public_token }

      redirect_to authorize_url(state), allow_other_host: true
    end

    # Stripe redirects the customer's browser back here.
    def callback
      pending = session.delete(:stripe_connect) || {}
      site = verify_state(pending)

      if site.nil?
        # `skip_authorization` IS REQUIRED HERE, and leaving it out is not a
        # style problem — it is a 500 on the failure path.
        #
        # ApplicationController runs `verify_authorized` as an after_action, so
        # returning from an action without calling `authorize` raises
        # Pundit::AuthorizationNotPerformedError. On this branch there is nothing
        # to authorize: the state did not match, so we do not know which site the
        # callback was for, and that is precisely the case where an unhandled
        # exception is worst — a forged or merely expired callback would answer
        # 500 and page somebody, instead of redirecting with an explanation.
        #
        # Documented rather than silent, as CLAUDE.md requires of every
        # skip_authorization.
        skip_authorization
        return redirect_to(sites_path, alert: connect_state_error)
      end

      authorize site.stripe_connections.new, :create?
      return redirect_to(site_path(site), alert: refusal_message) if params[:error].present?

      apply(site)
    end

    def destroy
      connection = @site.stripe_connections.live.first
      authorize connection || @site.stripe_connections.new, :destroy?

      connection&.revoke!
      # Disconnecting here stops us recording; it does not uninstall the app
      # from their Stripe account, and saying so spares the customer wondering
      # why it still appears in their installed-apps list.
      redirect_to site_path(@site),
                  notice: "Stripe disconnected. Revenue already recorded is kept. " \
                          "You can also uninstall the Tastatur app under Settings → Installed apps in Stripe."
    end

    def backfill
      connection = @site.stripe_connections.live.first
      authorize connection || @site.stripe_connections.new, :backfill?
      return redirect_to(site_path(@site), alert: "Connect Stripe first.") if connection.nil?

      BackfillStripeJob.perform_later(connection.id)
      redirect_to site_path(@site), notice: "Re-importing your Stripe history. This can take a few minutes."
    end

    private

    def apply(site)
      case ConnectStripeAccount.call(site: site, code: params[:code])
      in Success(connection)
        redirect_to site_path(site), notice: connected_message(connection)
      in Failure(invalid: message)
        redirect_to site_path(site), alert: message
      in Failure(oauth_error: message)
        redirect_to site_path(site), alert: "Stripe refused the connection: #{message}"
      in Failure(stripe_error: message)
        redirect_to site_path(site), alert: "Could not reach Stripe: #{message}"
      in Failure(reason)
        redirect_to site_path(site), alert: "Could not connect Stripe (#{reason})."
      end
    end

    def connected_message(connection)
      return "Stripe connected. Importing your history now." if connection.livemode

      "Stripe connected in TEST MODE. Figures here are test data, not real revenue."
    end

    # BOTH HALVES OF THE STATE ARE CHECKED, and the comparison is constant-time.
    #
    # A `state` that matches proves this callback belongs to a flow this browser
    # started. The site token is then re-resolved THROUGH policy_scope rather than
    # trusted from the session, so a session tampered with — or simply stale after
    # the user's membership was removed mid-flow — cannot attach a Stripe account
    # to a site they no longer have access to.
    def verify_state(pending)
      expected = pending["state"].to_s
      given = params[:state].to_s
      return nil if expected.blank? || given.blank?
      return nil unless ActiveSupport::SecurityUtils.secure_compare(expected, given)

      policy_scope(Site).find_by(public_token: pending["site"])
    end

    def connect_state_error
      "That Stripe connection link had expired or did not match this browser. Start again from the site page."
    end

    def refusal_message
      # Stripe sends `error=access_denied` when the customer clicks cancel, which
      # is not an error worth alarming anybody about.
      return "Stripe connection cancelled." if params[:error] == "access_denied"

      "Stripe refused the connection: #{params[:error_description].presence || params[:error]}"
    end

    def authorize_url(state)
      # The Stripe App install link. No `scope` parameter: what the customer is
      # asked to grant is the permission list in stripe-app/stripe-app.json,
      # which Stripe reviewed and renders on the consent screen. Read-only,
      # always — nothing in this application writes to a connected account and
      # nothing may start, so every permission in that manifest ends in `_read`.
      query = {
        client_id: Rails.configuration.stripe[:connect_client_id],
        redirect_uri: stripe_connect_callback_url,
        state: state
      }

      "https://marketplace.stripe.com/oauth/v2/authorize?#{query.to_query}"
    end

    def set_site
      @site = policy_scope(Site).find_by!(public_token: params[:site_public_token])
    end

    # Routes exist in every deployment so `site_stripe_connection_path` cannot
    # raise inside a view whose guard someone forgot — the same reasoning §14
    # gives for the billing routes — and the controller refuses instead.
    def ensure_revenue_enabled
      return if Tastatur.revenue_enabled?

      redirect_to root_path, alert: "Stripe Connect is not configured on this instance."
    end
  end
end
