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
  end

  # Custom registrations controller so a new user is given an account to own at
  # signup, and so signup can be closed on a self-hosted instance.
  devise_for :users, controllers: { registrations: "users/registrations" }

  # --- Application ----------------------------------------------------------
  resources :sites, param: :public_token do
    scope module: :sites do
      resource :installation, only: %i[show]
      resources :goals, except: %i[show]
      resources :funnels
      resources :shared_links, only: %i[index create destroy]
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

  # --- Compliance -----------------------------------------------------------
  get "privacy", to: "compliance#privacy"
  get "data-request", to: "compliance#data_request", as: :data_request
  get "dpa", to: "compliance#dpa"
  get "privacy-policy", to: "compliance#privacy_policy", as: :privacy_policy
  get "terms", to: "compliance#terms"

  # --- Onboarding -----------------------------------------------------------
  get "setup", to: "first_run#show", as: :first_run
  post "setup", to: "first_run#create"

  get "dashboard", to: "pages#dashboard"
  root to: "pages#home"

  require "sidekiq/web"
  require "sidekiq/cron/web"
  authenticate :user, ->(u) { u.respond_to?(:admin?) && u.admin? } do
    mount Sidekiq::Web => "/sidekiq"
  end

  # Health status on /up: 200 if the app boots and can reach PostgreSQL and
  # Redis, 503 otherwise.
  get "up", to: "health#show", as: :rails_health_check
end
