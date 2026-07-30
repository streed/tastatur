module Admin
  # Everything under /admin.
  #
  # The gate is a before_action rather than a per-action `authorize`, so a
  # controller or action added here later is protected by existing rather than by
  # its author remembering. Pundit's verify_authorized would catch a forgotten
  # call on a member action but NOT on an index — and index is exactly the shape
  # these screens take, so "protected unless you forget" is the wrong default for
  # pages that can see every account on the instance.
  #
  # Per-record `authorize` calls still appear on the member actions below, because
  # some of them have rules beyond "is a superuser" — revoking the last
  # administrator, for one.
  class BaseController < ApplicationController
    before_action :authorize_admin_console

    private

    def authorize_admin_console
      authorize %i[admin console], :show?
    end

    # `find_by_public_id!`, never `find`. See PubliclyIdentified: users are routed
    # by UUID so that /admin/users/4 cannot tell anyone how many customers exist.
    def scoped_users
      policy_scope([:admin, User])
    end
  end
end
