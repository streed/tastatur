class ApplicationController < ActionController::Base
  include Pundit::Authorization

  # Services return Dry::Monads results and callers are expected to pattern
  # match on them (`in Success(x)` / `in Failure(reason)`), which needs the
  # Success and Failure constants in scope. Including it here rather than in
  # each controller means no controller can forget and get a confusing
  # "uninitialized constant Success" at runtime.
  include Dry::Monads[:result]

  before_action :redirect_to_first_run_setup
  before_action :authenticate_user!

  # `if:`/`unless:` rather than `only: :index`. Since Rails 7.1, naming an
  # action in `only:` that the controller does not define raises — so
  # `only: :index` breaks every controller without an index action (which is
  # most of them). Testing action_name at request time gives the same behaviour
  # with no coupling to which actions happen to exist.
  after_action :verify_authorized, unless: :pundit_exempt?
  after_action :verify_policy_scoped, if: :pundit_scoped_action?

  # One form pattern everywhere, including Devise's own views. See
  # TastaturFormBuilder.
  default_form_builder TastaturFormBuilder

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  rescue_from Pundit::NotAuthorizedError, with: :deny_access
  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  helper_method :current_account, :current_membership

  # The account whose data is being viewed. Multi-account users switch with
  # ?account_slug=..., validated against their own memberships — a slug they are
  # not a member of falls back to their default rather than raising, so a stale
  # bookmark does not become an error page.
  #
  # The parameter is `account_slug`, NOT `account`, and the type is checked.
  # It used to be `account`, which collided with the account settings form: that
  # form posts `account: { name: ... }`, so `params[:account]` was an
  # ActionController::Parameters and `find_by(slug: <Parameters>)` raised
  # TypeError. The result was that account settings could not be saved at all,
  # and any visitor could produce a 500 with `?account[x]=1`.
  #
  # The type guard stays even after the rename, because `?account_slug[x]=1` is
  # just as easy to send and a reader should not have to trust that no form ever
  # nests under this name again.
  def current_account
    @current_account ||= begin
      slug = params[:account_slug]
      requested = slug.is_a?(String) && slug.present? ? current_user&.accounts&.find_by(slug: slug) : nil
      requested || current_user&.default_account
    end
  end

  def current_membership
    @current_membership ||= current_user&.membership_for(current_account)
  end

  private

  # An index action proves tenant isolation by scoping, not by authorizing a
  # single record — so it is held to verify_policy_scoped instead.
  #
  # These two used to contradict each other. `pundit_scoped_action?` required
  # `action_name == "index" && !pundit_exempt?`, while `pundit_exempt?` returned
  # true *for* index — so the condition was unsatisfiable and
  # `verify_policy_scoped` never ran on any action in the application. The
  # guarantee that an index page cannot leak another tenant's rows was resting on
  # a callback that was structurally unreachable.
  #
  # The isolation itself was fine, as it happens; every index action does call
  # `policy_scope`. What was missing was the thing that notices when a new one
  # doesn't.
  #
  # The exemption a Devise controller needs is genuine — its actions have no
  # record and no scope of ours — so it is factored out and applied to both
  # predicates rather than being tangled up with the index rule.
  def pundit_scoped_action?
    index_action? && !pundit_bypass?
  end

  def pundit_exempt?
    index_action? || pundit_bypass?
  end

  def index_action?
    action_name == "index"
  end

  def pundit_bypass?
    devise_controller?
  end

  # Pundit needs both the user and the account in scope to answer any question
  # about a site, so policies receive a small context object rather than a bare
  # user. This is what makes cross-tenant reads structurally impossible: a
  # policy cannot forget to check the account because the account is the
  # subject.
  def pundit_user
    AuthorizationContext.new(user: current_user, account: current_account)
  end

  def deny_access
    respond_to do |format|
      format.html { redirect_back fallback_location: root_path, alert: "You do not have access to that." }
      format.json { head :forbidden }
    end
  end

  def not_found
    respond_to do |format|
      format.html { render "errors/not_found", status: :not_found }
      format.json { head :not_found }
    end
  end

  # On a fresh self-hosted install (SELF_HOSTED=1 with no users yet) send the
  # operator to the setup wizard instead of a sign-in form they cannot use.
  #
  # `always_reachable?` is what stops this becoming a deployment deadlock. It
  # originally redirected EVERYTHING, which meant /up returned 302 on a fresh
  # install — so a platform health check never saw a 200, the deploy never went
  # healthy, and setup could never be completed because the service was never
  # brought up. A chicken-and-egg that only appears on the very first deploy,
  # which is the worst possible time to find it.
  #
  # The public informational pages are exempt for a plainer reason: they are
  # public. Nothing about an unconfigured instance makes its privacy policy or
  # licence terms private.
  def redirect_to_first_run_setup
    return unless Tastatur.needs_first_run_setup?
    return if controller_name == "first_run"
    return if self.class.always_reachable?(action_name)

    redirect_to first_run_path
  end

  # Declare a controller, or specific actions of it, reachable before first-run
  # setup has been completed:
  #
  #   always_reachable                 # the whole controller
  #   always_reachable only: %i[about] # just these actions
  def self.always_reachable(only: nil)
    @always_reachable_actions = only&.map(&:to_s) || :all
  end

  def self.always_reachable?(action)
    declared = @always_reachable_actions if defined?(@always_reachable_actions)

    return declared == :all || declared.include?(action.to_s) if declared

    superclass.respond_to?(:always_reachable?) ? superclass.always_reachable?(action) : false
  end
end
