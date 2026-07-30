module Admin
  # Authorizes entry to the admin area as a whole.
  #
  # Admin::BaseController authorizes this once, in a before_action, so a new
  # controller or a new action added later is gated by existing — rather than by
  # its author remembering to call `authorize`. Pundit's verify_authorized would
  # catch a missing call on a member action, but not on an index, and "the gate
  # is applied unless you forget" is the wrong default for the screens that can
  # see every account on the instance.
  class ConsolePolicy < BasePolicy
  end
end
