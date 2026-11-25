module Sites
  # Connecting an AI agent to a site, open to EVERY member of the organisation.
  #
  # A page of its own, not a corner of the API keys screen, for two reasons that
  # are the same reason. That screen is admin-only because its keys can write
  # identity; this one makes only keys that read, and a read key grants nothing its
  # maker cannot already see on the dashboard. And the instructions have to be
  # where a viewer can find them, which the admin-only settings page is not.
  #
  # The keys made here are always `read:analytics` and always owned by the member
  # who made them (see ApiKeyPolicy and ApiKey#owner_still_member?). Nothing in the
  # request chooses the scope, so there is no parameter to tamper with.
  class McpController < ApplicationController
    include SiteScoped

    def show
      authorize placeholder_key, :connect?
      @api_keys = keys.ordered
      @api_key = placeholder_key
    end

    def create
      key = ApiKey.generate!(site: @site, name: params.dig(:api_key, :name).to_s.strip,
                             scopes: AGENT_SCOPES, user: current_user)
      authorize key

      if key.save
        # In the flash for the same reason as on the API keys screen: read once,
        # then gone, and never in the session cookie.
        redirect_to site_mcp_path(@site),
                    flash: { api_key: key.plaintext, notice: "Key created. Copy it now — it is not shown again." }
      else
        @api_keys = keys.ordered
        @api_key = key
        render :show, status: :unprocessable_entity
      end
    end

    def destroy
      key = keys.find_by_public_id!(params[:public_id])
      authorize key

      key.revoke!
      redirect_to site_mcp_path(@site), notice: "#{key.name} revoked. The agent using it can no longer read this site."
    end

    private

    AGENT_SCOPES = ["read:analytics"].freeze

    # Scoped by policy: an admin gets every key on the account's sites, anyone
    # else gets their own. A key that is not theirs is therefore a 404, not a 403.
    def keys = policy_scope(ApiKey).where(site: @site).agent_keys

    def placeholder_key = ApiKey.new(site: @site, scopes: AGENT_SCOPES, user: current_user)
  end
end
