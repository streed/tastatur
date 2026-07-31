Rails.application.routes.draw do
  # --- Ingest ---------------------------------------------------------------
  # Called from customer sites, cross-origin, on every pageview. Kept at the
  # very top of the routing table because it is by a wide margin the most
  # requested path in the application and route matching is ordered.
  namespace :api do
    post "event", to: "events#create"
    get  "event", to: "events#create"        # for beacons that cannot POST
    match "event", to: "events#options", via: :options
    get "pixel", to: "events#pixel"

    # --- The authenticated server-to-server API -----------------------------
    # Versioned, unlike the ingest routes above, and for a plain reason: those are
    # baked into a script tag on pages we do not control and can never change,
    # whereas this is called by code the customer deploys and can update. A
    # version segment is only worth carrying where a v2 is actually possible.
    #
    # Authenticated by an ApiKey, NOT by the public site token — see the
    # CreateApiKeys migration for why identity writes must not be forgeable by
    # anyone who can view source on a customer's homepage.
    namespace :v1 do
      post "identify", to: "identify#create"
    end
  end

  # Custom registrations controller so a new user is given an account to own at
  # signup, and so signup can be closed on a self-hosted instance. Custom
  # sessions controller so a password can be accepted without the sign-in being
  # finished — see Users::SessionsController and the two-factor routes below.
  devise_for :users, controllers: {
    registrations: "users/registrations",
    sessions: "users/sessions"
  }

  # --- Two-factor authentication --------------------------------------------
  # The challenge is deliberately NOT under /users with Devise's own routes. It
  # is reached with no session at all, holding only a short-lived pending marker,
  # and a path that looks like part of Devise invites the assumption that Devise
  # is enforcing something here. It is not; TwoFactor::PendingSignIn is.
  get    "two-factor",        to: "two_factor/challenges#show",    as: :two_factor_challenge
  post   "two-factor",        to: "two_factor/challenges#create"
  post   "two-factor/resend", to: "two_factor/challenges#resend",  as: :resend_two_factor_challenge
  delete "two-factor",        to: "two_factor/challenges#destroy", as: :cancel_two_factor_challenge

  # Turning it on and off, and forgetting devices. Authenticated, unlike the
  # three above, and rendered inside the account page rather than on screens of
  # their own.
  resource :two_factor_setting, only: %i[create destroy],
                                path: "settings/two-factor",
                                controller: "two_factor/settings"

  resources :trusted_devices, only: %i[destroy],
                              path: "settings/trusted-devices",
                              param: :public_id,
                              controller: "two_factor/trusted_devices" do
    delete :all, on: :collection, action: :destroy_all
  end

  # --- Application ----------------------------------------------------------
  resources :sites, param: :public_token do
    scope module: :sites do
      resource :installation, only: %i[show]
      resources :goals, except: %i[show]
      resources :funnels
      resources :dashboards
      resources :shared_links, only: %i[index create destroy]

      # --- Revenue ----------------------------------------------------------
      # The attribution screen is the product; customers is how you read one row
      # of it. Both are reports and are open to viewers (see CustomerPolicy).
      get "attribution", to: "attribution#show"
      resources :customers, only: %i[index show], param: :public_id

      resources :api_keys, only: %i[index create destroy], param: :public_id
    end

    # Admin-and-up. A singular resource because a site has at most one live
    # connection, which a partial unique index enforces.
    #
    # POINTED AT `revenue/` RATHER THAN `sites/`, unlike everything in the block
    # above, so that all four actions of the OAuth flow live in one controller.
    # The callback below cannot be nested here — Stripe matches redirect URIs
    # exactly, so it has to be one fixed path — and splitting "start the flow"
    # from "finish the flow" across two controllers is how the CSRF state check
    # ends up implemented in only one of them.
    scope module: :revenue do
      resource :stripe_connection, only: %i[create destroy] do
        post :backfill, on: :collection
      end
    end
  end

  resource :account, only: %i[show edit update] do
    resources :members, only: %i[index create update destroy], module: :accounts
  end

  # --- Billing --------------------------------------------------------------
  # All four routes exist on a self-hosted install too, and all four refuse to
  # render there (see BillingController#ensure_billing_enabled). Defining them
  # conditionally would mean `billing_path` raising NoMethodError inside a view
  # whose guard someone forgot — a missing guard should show an operator a
  # redirect, not a 500.
  get  "billing", to: "billing#show", as: :billing
  post "billing/checkout", to: "billing#checkout", as: :billing_checkout
  post "billing/portal", to: "billing#portal", as: :billing_portal

  # Stripe's callback. On its own line and in its own comment block for the same
  # reason the public shared dashboards below are not nested: an endpoint that is
  # unauthenticated and exempt from CSRF should be visible as such in the routing
  # table rather than hidden inside an authenticated resource.
  post "billing/stripe/webhook", to: "billing/stripe_webhooks#create", as: :stripe_webhook

  # --- Stripe Connect (the CUSTOMER'S Stripe account) -----------------------
  #
  # A DIFFERENT STRIPE INTEGRATION FROM THE THREE ROUTES ABOVE, and the separation
  # is deliberate rather than incidental. `/billing/*` is money flowing to us:
  # our account, our subscription, our webhook secret. These are money flowing to
  # our CUSTOMER: their account, read-only, reached through Connect. Two features
  # that both say "Stripe" and mean opposite directions is exactly the confusion
  # that puts a write into the wrong one, so they do not share a namespace, a
  # controller, a webhook endpoint or a signing secret.
  #
  # BOTH OF THESE ARE FIXED PATHS, not nested under /sites/:token, because Stripe
  # matches redirect URIs and webhook endpoints exactly — a per-site path would
  # have to be registered per site, which is not a thing. Which site a callback
  # belongs to travels in the OAuth `state` parameter; which site a webhook
  # belongs to is resolved from the connected account id on the event.
  get  "stripe/connect/callback", to: "revenue/stripe_connections#callback", as: :stripe_connect_callback
  post "stripe/connect/webhook",  to: "revenue/connect_webhooks#create",     as: :stripe_connect_webhook

  # --- Public shared dashboards --------------------------------------------
  # Deliberately NOT nested under /sites: these are reached by unguessable slug
  # with no session, and keeping them on their own path makes it obvious in the
  # routing table which endpoints are unauthenticated.
  get  "share/:slug", to: "shared_dashboards#show", as: :shared_dashboard
  post "share/:slug/unlock", to: "shared_dashboards#unlock", as: :unlock_shared_dashboard

  # --- The tracking script --------------------------------------------------
  #
  # Served by the application rather than from public/, so its cache header is
  # right on every deployment instead of only the one that happens to have Caddy
  # in front. The path is embedded in customer pages and cannot change.
  # See TrackerController for the year-long-cache bug this replaced.
  get "t.js", to: "tracker#show", as: :tracker

  # --- Documentation --------------------------------------------------------
  get "docs", to: "docs#show"
  get "about", to: "pages#about"
  get "pricing", to: "pricing#show"

  # The questions people ask before choosing an analytics tool. No `format:
  # false` here, unlike llms.txt below: this one WANTS Rails' implicit
  # `(.:format)` segment, because /faq.md is how a machine reader fetches it
  # without content negotiation — exactly as /docs.md does.
  get "faq", to: "pages#faq"

  # The revenue-attribution marketing page. Same two-format contract as /faq:
  # /revenue.md is the machine reader's copy.
  get "revenue", to: "pages#revenue"

  # The llms.txt convention (https://llmstxt.org): a markdown index at a
  # well-known path telling an AI agent what is here and where the
  # markdown-native pages live. `format: false` keeps ".txt" as a literal part
  # of the path instead of letting Rails read it as a format; the default then
  # pins the response to markdown regardless of the Accept header. /index.md is
  # the marketing page's directly fetchable markdown URL — the root route has no
  # format segment, and an index that says "send this Accept header" is a worse
  # index than a link.
  get "llms.txt", to: "pages#llms", as: :llms, format: false, defaults: { format: :md }
  get "index.md", to: "pages#home", as: :markdown_root, format: false, defaults: { format: :md }

  # robots.txt and sitemap.xml, served by the application rather than out of
  # public/ — see CrawlersController for the two bugs that decision avoids, and
  # note that public/robots.txt must stay deleted or the first of these is never
  # reached, since ActionDispatch::Static runs ahead of the router.
  # `format: false` keeps the extension a literal part of the path exactly as it
  # does for llms.txt above, so ".xml" is not read as a format and negotiated
  # away by an Accept header.
  get "robots.txt", to: "crawlers#robots", as: :robots, format: false, defaults: { format: :text }
  get "sitemap.xml", to: "crawlers#sitemap", as: :sitemap, format: false, defaults: { format: :xml }

  # --- Compliance -----------------------------------------------------------
  get "privacy", to: "compliance#privacy"
  get "dpa", to: "compliance#dpa"
  get "privacy-policy", to: "compliance#privacy_policy", as: :privacy_policy
  get "terms", to: "compliance#terms"

  # --- Onboarding -----------------------------------------------------------
  get "setup", to: "first_run#show", as: :first_run
  post "setup", to: "first_run#create"

  get "dashboard", to: "pages#dashboard"
  root to: "pages#home"

  # --- Instance administration ----------------------------------------------
  # The `admin` flag on User: an operator of this installation, which is a
  # different thing from being an admin OF an account. See Admin::BasePolicy.
  namespace :admin do
    root to: "dashboard#show"

    # Members are addressed by public_id, not by id — /admin/users/4 would tell
    # anyone who saw it roughly how many customers exist. See PubliclyIdentified.
    resources :users, only: %i[index show] do
      member do
        post   :confirm
        post   :unlock
        post   :resend_confirmation
        post   :send_password_reset
        post   :grant_admin
        delete :revoke_admin
        # Off only. There is no matching route to turn it on — see
        # Admin::UserPolicy#disable_two_factor? for why that asymmetry is the
        # whole point.
        delete :two_factor, action: :disable_two_factor
      end
    end

    # Listed, never opened. Admin::SitePolicy has no show action on purpose.
    resources :sites, only: %i[index]

    # No index and no show — accounts are reached through the person who wrote
    # in, from the accounts card on their user page.
    resources :accounts, only: [] do
      member do
        patch :plan, action: :update_plan
      end
    end
  end

  require "sidekiq/web"
  require "sidekiq/cron/web"
  authenticate :user, ->(u) { u.respond_to?(:admin?) && u.admin? } do
    mount Sidekiq::Web => "/sidekiq"
  end

  # Health status on /up: 200 if the app boots and can reach PostgreSQL and
  # Redis, 503 otherwise.
  get "up", to: "health#show", as: :rails_health_check
end
