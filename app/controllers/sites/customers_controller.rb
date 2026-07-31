module Sites
  # The customer list, and one customer's first touch and revenue history.
  #
  # This is where somebody goes to answer "is this attribution actually right?" —
  # so the detail page shows the provenance of every field rather than only the
  # conclusion. An attribution number nobody can audit is a number nobody trusts
  # for long.
  class CustomersController < ApplicationController
    include SiteScoped

    PER_PAGE = 50

    def index
      # `policy_scope` rather than `@site.customers`, so tenant isolation on this
      # page rests on the same one rule as everywhere else rather than on the
      # SiteScoped lookup alone. verify_policy_scoped enforces that it is called.
      scope = policy_scope(Customer).where(site: @site)
      scope = scope.where.not(converted_at: nil) if params[:filter] == "paying"
      scope = search(scope)

      @page = [params[:page].to_i, 1].max
      @total = scope.count
      @customers = scope.ordered.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
      @pages = (@total / PER_PAGE.to_f).ceil
      @connection = @site.stripe_connection
    end

    def show
      @customer = policy_scope(Customer).where(site: @site).find_by_public_id!(params[:public_id])
      authorize @customer

      @subscriptions = @customer.customer_subscriptions.order(created_at: :desc)
      @revenue_events = @customer.revenue_events.order(occurred_at: :desc).limit(100)
    end

    private

    # SEARCHES THE EXTERNAL ID AND THE STRIPE ID, AND DELIBERATELY NOT THE EMAIL.
    #
    # There is no email column to search — only `email_hash` — and that is the
    # design rather than an omission. But somebody will reasonably try typing an
    # address into this box, so the hash of what they typed is compared too: it
    # finds the right customer for an exact address, and finds nothing for a
    # partial one, which is the correct behaviour for a value we cannot match on
    # prefix.
    def search(scope)
      term = params[:q].to_s.strip
      return scope if term.blank?

      scope.where(
        "external_id ILIKE :like OR stripe_customer_id ILIKE :like OR email_hash = :hash",
        like: "%#{term}%", hash: Customer.hash_email(term)
      )
    end
  end
end
