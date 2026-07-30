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
  get "data-request", to: "compliance#data_request", as: :data_request
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
