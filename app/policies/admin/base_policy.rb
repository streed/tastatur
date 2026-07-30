module Admin
  # Instance-wide administration, which asks a different question from every
  # other policy in this application.
  #
  # Everywhere else the question is "what may this person do inside the account
  # they are currently acting as", and ApplicationPolicy answers it from their
  # membership. Here the account is irrelevant and must be: an instance
  # administrator helping a customer is not a member of that customer's account,
  # and requiring them to become one to read a support screen would mean granting
  # themselves access to a tenant's data as a matter of routine.
  #
  # So these policies deliberately do NOT inherit from ApplicationPolicy. Its
  # defaults all reduce to `member?`, and inheriting them would mean an admin
  # policy that forgot to override an action would fall through to "is this
  # person a member of the account they happen to be acting as" — which for an
  # admin is both the wrong question and, on their own personal account, often
  # true.
  #
  # They live under Admin:: for the same reason. `authorize [:admin, user]`
  # resolves here and `authorize user` cannot, so the two can never be confused
  # at a call site.
  class BasePolicy
    attr_reader :context, :record

    def initialize(context, record)
      @context = context
      @record = record
    end

    # The one gate. Every predicate below is this, and subclasses narrow rather
    # than widen — there is no admin action that a non-superuser may take.
    def superuser? = context.superuser?

    def index?   = superuser?
    def show?    = superuser?
    def create?  = superuser?
    def new?     = create?
    def update?  = superuser?
    def edit?    = update?
    def destroy? = superuser?

    # Fails closed, like ApplicationPolicy::Scope, and for the same reason: a
    # subclass that forgets to override this shows an empty page — a bug someone
    # reports — rather than every user on the instance.
    class Scope
      attr_reader :context, :scope

      delegate :user, :superuser?, to: :context

      def initialize(context, scope)
        @context = context
        @scope = scope
      end

      def resolve
        scope.none
      end
    end
  end
end
