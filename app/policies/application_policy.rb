# frozen_string_literal: true

class ApplicationPolicy
  attr_reader :context, :record

  delegate :user, :account, :membership, :at_least?, :member?, to: :context

  def initialize(context, record)
    @context = context
    @record = record
  end

  def index?  = member?
  def show?   = member?
  def create? = at_least?(:member)
  def new?    = create?
  def update? = at_least?(:member)
  def edit?   = update?
  def destroy? = at_least?(:admin)

  class Scope
    attr_reader :context, :scope

    delegate :user, :account, to: :context

    def initialize(context, scope)
      @context = context
      @scope = scope
    end

    # Every Scope subclass must narrow to the current account. The base class
    # returns NOTHING rather than everything, so a subclass that forgets to
    # override this leaks no data — it just shows an empty page, which is a bug
    # someone reports rather than a breach nobody notices.
    def resolve
      scope.none
    end
  end
end
