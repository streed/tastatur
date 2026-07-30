class SitesController < ApplicationController
  before_action :set_site, only: %i[show edit update destroy]

  def index
    @sites = policy_scope(Site).ordered
    redirect_to new_site_path if @sites.empty?
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

  def new
    @site = current_account.sites.new
    authorize @site
  end

  def create
    @site = current_account.sites.new(site_params)
    authorize @site

    if @site.save
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

    if @site.update(site_params)
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
    params.expect(site: %i[domain timezone k_anonymity_threshold extra_hostnames_list enforce_hostname])
  end
end
