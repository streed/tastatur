module Sites
  # Minting and revoking the server-side credentials.
  #
  # THE PLAINTEXT IS RENDERED EXACTLY ONCE, out of the flash, and never stored.
  # A screen that can show you your own API key again later is a screen whose
  # database read is equivalent to holding the key — so this shows it on the
  # redirect that follows creation and never again, and says so on the page.
  class ApiKeysController < ApplicationController
    include SiteScoped

    def index
      @api_keys = policy_scope(ApiKey).where(site: @site).ordered
      @api_key = ApiKey.new
    end

    def create
      key = ApiKey.generate!(site: @site, name: params.dig(:api_key, :name).to_s.strip)
      authorize key

      if key.save
        # IN THE FLASH, NOT THE SESSION, and not a database column.
        #
        # `flash` is read once and cleared, which is the exact lifetime this value
        # should have. Putting it in the session would leave a live credential
        # sitting in the user's cookie for the rest of their session, readable by
        # anything that can read the cookie — which is a strictly worse place for
        # it than the clipboard it is about to be copied to.
        redirect_to site_api_keys_path(@site),
                    flash: { api_key: key.plaintext, notice: "API key created. Copy it now — it is not shown again." }
      else
        @api_keys = policy_scope(ApiKey).where(site: @site).ordered
        @api_key = key
        render :index, status: :unprocessable_entity
      end
    end

    def destroy
      key = policy_scope(ApiKey).where(site: @site).find_by_public_id!(params[:public_id])
      authorize key

      # REVOKED, NOT DELETED. A destroyed key takes with it the answer to "when
      # did this stop working, and was that before or after the incident?" — which
      # is the first question anybody asks in the situation that caused the
      # revocation.
      key.revoke!
      redirect_to site_api_keys_path(@site), notice: "#{key.name} revoked. Requests using it now fail."
    end
  end
end
