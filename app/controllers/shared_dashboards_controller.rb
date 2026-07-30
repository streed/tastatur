# Read-only dashboards reachable without an account.
#
# This is the highest-risk controller in the application: it is unauthenticated
# and it renders another tenant's statistics. Every defence is therefore
# explicit rather than inherited.
#
#   - It NEVER reads params[:site], an id, or a domain. The only input is an
#     unguessable 143-bit slug, so there is nothing to enumerate and nothing to
#     tamper with. A wrong slug is a 404, indistinguishable from a revoked one.
#
#   - It resolves the site THROUGH the link, so the link is the sole authority
#     on which site is visible. There is no code path here that could be
#     tricked into pairing one tenant's link with another tenant's data.
#
#   - Expiry and password are checked before any query runs.
#
#   - Public dashboards are always held to the site's suppression threshold, and
#     filters are not offered — a filterable public dashboard is a
#     re-identification tool pointed at someone else's audience.
#
# On the session cookie: unlocking a password-protected dashboard sets one. That
# is a first-party cookie on OUR application, set for someone who typed a
# password, and it is unrelated to the promise made about visitors of measured
# sites — nobody's site gets a cookie because of this.
class SharedDashboardsController < ApplicationController
  skip_before_action :authenticate_user!
  skip_after_action :verify_authorized

  layout "public_dashboard"

  before_action :set_shared_link
  before_action :require_unlock, only: :show

  def show
    @site = @shared_link.site
    @period = Analytics::Period.parse(params[:period], site: @site)

    # Filters are deliberately not honoured here. See the class comment.
    @report = Analytics::Dashboard.call(site: @site, period: @period).value!
    @shared_link.record_view!
  end

  def unlock
    if @shared_link.authenticate_password(params[:password].to_s)
      session[unlock_key] = true
      redirect_to shared_dashboard_path(@shared_link.slug)
    else
      # A deliberate, constant-ish delay: this is an unauthenticated password
      # endpoint, and Rack::Attack throttles it too.
      sleep 0.5
      redirect_to shared_dashboard_path(@shared_link.slug), alert: "Incorrect password."
    end
  end

  private

  def set_shared_link
    @shared_link = SharedLink.find_by!(slug: params[:slug])
    # An expired link is a 404 rather than a 403: distinguishing them tells an
    # anonymous caller that the slug was once valid.
    raise ActiveRecord::RecordNotFound if @shared_link.expired?
  end

  def require_unlock
    return unless @shared_link.password_protected?
    return if session[unlock_key]

    render :locked, status: :unauthorized
  end

  def unlock_key
    "shared_link_#{@shared_link.id}_unlocked"
  end
end
