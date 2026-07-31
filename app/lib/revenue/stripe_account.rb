module Revenue
  # The one place that knows how to talk to a connected Stripe account.
  #
  # Every call into a customer's Stripe account goes through `options` so there is
  # exactly one answer to "how do we authenticate against a connected account",
  # and so the answer can be changed in one file if Stripe ever removes the
  # `Stripe-Account` header form.
  #
  # THE OPTIONS HASH IS THE SECOND POSITIONAL ARGUMENT, NOT PARAMS, and confusing
  # the two is a documented trap in this codebase already — see the note in
  # Billing::SyncSubscription about `retrieve(id, expand: [...])` failing inside
  # Net::HTTP. The gem turns any unrecognised key in `opts` into an HTTP header,
  # so a params key smuggled in here does not raise a useful error; it produces a
  # malformed request. Hence the helpers below, which put each thing where it goes.
  module StripeAccount
    module_function

    # Per-request options identifying which connected account to act on.
    #
    # `stripe_account` is what makes the platform's own secret key read a
    # customer's data, and it is why no access token is stored anywhere. See the
    # StripeConnection model.
    def options(connection)
      { stripe_account: connection.stripe_account_id }
    end

    # `Stripe::Subscription.list` and friends, scoped to a connected account.
    #
    # A thin wrapper on purpose: it exists so that no call site has to remember
    # the params/opts split, and so a spec can stub one method rather than every
    # Stripe resource class.
    def list(resource, connection, params = {})
      resource.list(params, options(connection))
    end

    def retrieve(resource, connection, id, params = {})
      # The id folds into the params hash rather than being passed positionally,
      # which is the form that survives an `expand:` being added later.
      resource.retrieve({ id: id }.merge(params), options(connection))
    end

    # Paginates with `auto_paging_each`, which the gem implements by following
    # `has_more` — so it carries the original options and needs nothing extra.
    #
    # `auto_paging_each` rather than a manual `starting_after` loop because the
    # manual version has an off-by-one that only appears past the first page,
    # which is exactly the size of dataset nobody tests the backfill against.
    def each(resource, connection, params = {}, &block)
      list(resource, connection, { limit: 100 }.merge(params)).auto_paging_each(&block)
    end
  end
end
