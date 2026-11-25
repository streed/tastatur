module Accounts
  # Connecting an AI agent to an ACCOUNT, open to EVERY member of it.
  #
  # Account-level because a member's access is: a membership is of an account, so
  # the key an agent holds reaches every site the member can already see, and an
  # organisation with eight sites makes one key rather than eight. It was per-site
  # first and was too cumbersome to use.
  #
  # A page of its own, not a corner of the API keys screen, for two reasons that are
  # the same reason. That screen is admin-only because its keys can write identity;
  # this one makes only keys that read, and a read key grants nothing its maker
  # cannot already see on the dashboard. And the instructions have to be where a
  # viewer can find them.
  #
  # The keys made here are always `read:analytics` and always owned by the member
  # who made them (see ApiKeyPolicy and ApiKey#owner_still_member?). Nothing in the
  # request chooses the scope, so there is no parameter to tamper with.
  class McpController < ApplicationController
    AGENT_SCOPES = ["read:analytics"].freeze

    def show
      authorize placeholder_key, :connect?
      @account = current_account
      @sites = @account.sites.order(:domain)
      @api_keys = keys.ordered
      @api_key = placeholder_key
    end

    def create
      key = ApiKey.generate!(account: current_account, name: params.dig(:api_key, :name).to_s.strip,
                             scopes: AGENT_SCOPES, user: current_user)
      authorize key

      if key.save
        # In the flash for the same reason as on the API keys screen: read once,
        # then gone, and never in the session cookie.
        redirect_to account_mcp_path, flash: { api_key: key.plaintext, notice: "Key created. Copy it now — it is not shown again." }
      else
        @account = current_account
        @sites = @account.sites.order(:domain)
        @api_keys = keys.ordered
        @api_key = key
        render :show, status: :unprocessable_entity
      end
    end

    def destroy
      key = keys.find_by_public_id!(params[:public_id])
      authorize key

      key.revoke!
      redirect_to account_mcp_path, notice: "#{key.name} revoked. The agent using it can no longer read this account."
    end

    private

    # Scoped by policy: an admin gets every agent key on the account, anyone else
    # gets their own. A key that is not theirs is therefore a 404, not a 403.
    def keys = policy_scope(ApiKey).where(account: current_account).agent_keys

    def placeholder_key = ApiKey.new(account: current_account, scopes: AGENT_SCOPES, user: current_user)
  end
end
