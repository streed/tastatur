module Revenue
  # Finds the Customer a set of identifiers refers to, or nil.
  #
  # A QUERY OBJECT, NOT AN ApplicationService, and deliberately so. Everything in
  # app/services returns a Result because it performs an operation that can
  # meaningfully fail. This answers a question whose honest answer is sometimes
  # "nobody" — wrapping that in `Failure(:not_found)` would make every one of the
  # four call sites pattern-match a non-event. `app/lib/<namespace>` is where this
  # codebase already puts collaborators of that kind (Ingest::HostnamePolicy,
  # Billing::EventQuota).
  #
  # THE ORDER OF THE THREE KEYS IS THE WHOLE DESIGN, from most authoritative to
  # least:
  #
  #   external_id         the customer's own primary key. They told us this
  #                       directly and it cannot be wrong.
  #   stripe_customer_id  authoritative too, but arrives from Stripe rather than
  #                       from the application, so it is second.
  #   email_hash          a guess, and treated like one.
  #
  # A later key never overrides a match from an earlier one, which is what stops a
  # shared billing address ("billing@acme.com" on four accounts) from collapsing
  # four real customers into one.
  module CustomerMatcher
    module_function

    def call(site:, external_id: nil, stripe_customer_id: nil, email_hash: nil)
      by_external_id(site, external_id) ||
        by_stripe_customer_id(site, stripe_customer_id) ||
        by_email_hash(site, email_hash)
    end

    def by_external_id(site, external_id)
      return nil if external_id.blank?

      site.customers.find_by(external_id: external_id)
    end

    def by_stripe_customer_id(site, stripe_customer_id)
      return nil if stripe_customer_id.blank?

      site.customers.find_by(stripe_customer_id: stripe_customer_id)
    end

    # AN AMBIGUOUS EMAIL IS NO MATCH AT ALL, and this is the one place in the
    # matcher where doing less is the correct behaviour.
    #
    # The email index is deliberately not unique (see the migration): two people
    # can legitimately share an address across two of the customer's own accounts,
    # and refusing the second signup to protect a fallback join would lose a real
    # paying customer. The consequence is that this lookup can return two rows,
    # and there is no information available here to choose between them.
    #
    # Picking the first would attach a subscription — and therefore revenue, and
    # therefore attribution — to a coin flip. Returning nil instead means the
    # caller creates a new customer whose revenue is real and whose attribution is
    # unknown, which is a smaller and much more visible error than silently
    # crediting the wrong campaign.
    def by_email_hash(site, email_hash)
      return nil if email_hash.blank?

      matches = site.customers.where(email_hash: email_hash).limit(2).to_a
      return nil unless matches.one?

      matches.first
    end
  end
end
