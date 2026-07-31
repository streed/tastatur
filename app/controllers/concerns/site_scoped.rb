# Resolves the site every controller nested under /sites/:site_public_token
# works within.
#
# Looked up through policy_scope, not Site.find — so a token belonging to
# another account raises RecordNotFound before any authorization question is
# even asked. That lookup is the tenant boundary for everything nested under a
# site, which is exactly why it lives in one place: five controllers each
# carrying their own copy is five chances for the sixth to skip the scope.
#
# SitesController itself does not include this — its param is :public_token,
# not :site_public_token, because there the site is the routed resource rather
# than the scope around one.
module SiteScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_site
  end

  private

  def set_site
    @site = policy_scope(Site).find_by!(public_token: params[:site_public_token])
  end
end
