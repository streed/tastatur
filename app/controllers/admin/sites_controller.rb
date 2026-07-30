module Admin
  # Sites are listed, never opened. See Admin::SitePolicy for why there is no
  # show action and why adding one would be a change to what /dpa promises.
  class SitesController < BaseController
    def index
      @query = params[:q]
      @sites = policy_scope([:admin, Site])
               .then { |scope| @query.present? ? search(scope, @query) : scope }
               .includes(:account)
               .order(created_at: :desc)
               .limit(100)
    end

    private

    # Domain or token. The token is the one a customer will quote, because it is
    # the string in the snippet they pasted and the only identifier they can see
    # without signing in.
    def search(scope, query)
      term = "%#{Site.sanitize_sql_like(query.strip)}%"
      scope.where("domain ILIKE :t OR public_token ILIKE :t", t: term)
    end
  end
end
