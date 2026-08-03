class SitesController < ApplicationController
  before_action :set_site, only: %i[show edit update destroy]

  # An account with no sites yet is sent straight to the form, because the empty
  # list is not information — it is a step.
  #
  # `policy(Site).create?` guards it, and that guard is load-bearing rather than
  # tidy. Without it, anyone who cannot create a site and has none to look at is
  # redirected to a form that refuses them; `deny_access` then redirects *back*
  # using the referer, which is this page, which redirects to the form again.
  # That is a genuine loop, and it is reachable by two ordinary people: a viewer
  # in an account whose sites were all deleted, and — since site creation now
  # requires a confirmed address — anyone who has not confirmed one.
  def index
    @sites = policy_scope(Site).ordered
    return redirect_to new_site_path if @sites.empty? && policy(Site).create?

    # ONE query for every site on the page, not one per site. See
    # Analytics::SiteTotals — it reads events_by_hour, so the cost is a few
    # thousand aggregate rows rather than a scan of the raw hypertable.
    @totals = Analytics::SiteTotals.call(sites: @sites).value!
  end

  # The dashboard.
  def show
    authorize @site, :stats?

    @period = Analytics::Period.parse(params[:period], site: @site, from: params[:from], to: params[:to])
    @filters = Analytics::Filters.from_params(params)
    @report = Analytics::Dashboard.call(site: @site, period: @period, filters: @filters).value!

    # Drilling into a breakdown row navigates the "dashboard" frame rather than the
    # whole page, so the response skips the layout, the site header and the period
    # switcher. The partial emits the <turbo-frame> itself — it has to, since Turbo
    # swaps in the matching frame from the RESPONSE and there is no layout here to
    # supply one.
    return unless turbo_frame_request?

    render partial: "sites/dashboard",
           locals: { site: @site, report: @report, filters: @filters, drillable: true }
  end

  # `current_account` is nil for a signed-in user who belongs to no account, and
  # `nil.sites` is a 500. Registration always creates an account, so this is the
  # leftover case: the user's only account was deleted while their session lived on.
  # Rare, reachable, and a blank error page is a poor way to discover it.
  before_action :require_account, only: %i[new create]

  # SitePolicy#create? already refuses an unconfirmed address, and would do so
  # with "You do not have access to that." — which is true, useless, and reads
  # like a permissions problem the person should ask an admin about. This runs
  # first purely so the refusal names the actual reason and the actual remedy.
  # The policy remains the enforcement; this is the explanation.
  before_action :require_confirmed_email, only: %i[new create]

  def new
    @site = current_account.sites.new
    authorize @site
  end

  def create
    @site = current_account.sites.new(site_params)
    authorize @site

    if save_site
      redirect_to site_installation_path(@site), notice: "Site added. Install the snippet to start collecting."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @site
  end

  def update
    authorize @site
    @site.assign_attributes(site_params)

    if save_site
      redirect_to site_path(@site), notice: "Settings saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @site

    domain = @site.domain
    Sites::Delete.call(site: @site)
    redirect_to sites_path, notice: "#{domain} and all of its data were deleted."
  end

  private

  # `add_index :sites, %i[account_id domain], unique: true`, by its Rails-derived
  # name. Matched against the driver's message because that is the only thing
  # ActiveRecord surfaces about *which* constraint was violated.
  DUPLICATE_DOMAIN_INDEX = "index_sites_on_account_id_and_domain".freeze

  # The uniqueness validation SELECTs and the unique index enforces, and a second
  # request fits between the two — a double-clicked submit button is enough. Left
  # alone that race is a 500 and a Sentry alert for a situation the form already
  # has a perfectly good message for, so it is turned back into the 422 the
  # validation would have produced a millisecond earlier.
  #
  # `errors.add(:domain, :taken)` rather than a literal string: that is the same
  # i18n key the uniqueness validator uses, so the two paths cannot drift apart
  # and a customised message only has to be written once.
  #
  # Deliberately narrow. Only the domain index is translated; a collision on
  # public_token means the 1.2e24-space generator in Site is broken, and that is
  # a bug to raise rather than to report to a customer as a duplicate domain.
  def save_site
    @site.save
  rescue ActiveRecord::RecordNotUnique => e
    raise unless e.message.include?(DUPLICATE_DOMAIN_INDEX)

    @site.errors.add(:domain, :taken)
    false
  end

  def require_confirmed_email
    return if current_user.confirmed?

    # `skip_authorization` for the same reason as require_account below: the
    # refusal happens before there is a record to authorize, and the reason it
    # happens has nothing to do with the account. Documented rather than assumed,
    # per CLAUDE.md.
    skip_authorization
    redirect_to sites_path,
                alert: "Confirm your email address before adding a site. " \
                       "We sent a link when you signed up — check your spam folder, or request another."
  end

  def require_account
    return if current_account.present?

    # `skip_authorization` because there is no record to authorize and no account
    # to authorize it against — the whole point is that neither exists yet.
    skip_authorization
    redirect_to root_path,
                alert: "Your account is no longer available. Ask an owner to invite you, or create a new account."
  end

  # Looked up through policy_scope, not Site.find — so a token belonging to
  # another account raises RecordNotFound before any authorization question is
  # even asked.
  def set_site
    @site = policy_scope(Site).find_by!(public_token: params[:public_token])
  end

  def site_params
    params.expect(site: %i[domain timezone k_anonymity_threshold extra_hostnames_list enforce_hostname
                           base_currency path_patterns_list])
  end
end
