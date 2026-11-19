---
paths:
  - "app/services/**/*.rb"
  - "spec/services/**/*.rb"
  - "app/values/**/*.rb"
---

```ruby
class ChargeCustomer < ApplicationService
  def initialize(user:, amount_cents:)
    @user = user
    @amount_cents = amount_cents
  end

  def call
    return Failure(:no_payment_method) unless @user.stripe_customer_id

    charge = Stripe::Charge.create(
      customer: @user.stripe_customer_id,
      amount:   @amount_cents,
      currency: "usd"
    )
    Success(charge)
  rescue Stripe::StripeError => e
    Failure(stripe_error: e.message)
  end
end
```

Callers pattern-match the result:

```ruby
case ChargeCustomer.call(user:, amount_cents: 1500)
in Success(charge) then redirect_to charge_path(charge.id)
in Failure(:no_payment_method) then redirect_to billing_path
in Failure(stripe_error:) then flash[:error] = stripe_error
end
```
