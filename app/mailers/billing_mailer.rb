class BillingMailer < ApplicationMailer
  # "You are close to your monthly allowance", or "you are past it".
  #
  # This is the only billing email Tastatur sends itself. Receipts, card-expiry
  # warnings and failed-payment dunning are all sent by Stripe, which owns the
  # payment state and already does it properly — adding our own would either
  # duplicate Stripe's message or contradict it, and both are worse than either
  # one alone.
  #
  # A usage warning is different: Stripe knows nothing about how many events we
  # have recorded, so if we do not send this, nobody does. The failure it prevents
  # is a customer whose numbers stop moving and who reasonably concludes the
  # product is broken.
  #
  # The level is passed as a string rather than the usage snapshot because this is
  # delivered with deliver_later: ActiveJob serialises arguments, and a Dry::Struct
  # is not serialisable. Re-measuring here also means the figures in the email are
  # the ones at send time rather than at enqueue time.
  def usage_threshold(account, recipient, level)
    @account = account
    @recipient = recipient
    @level = level.to_s
    @usage = Billing::MeasureUsage.call(account: account).value!
    @billing_url = billing_url

    mail(
      to: recipient.email,
      subject: subject_for(@level)
    )
  end

  private

  def subject_for(level)
    if level == "exceeded"
      "#{@account.name} has used its #{@usage.plan.name} plan's monthly events"
    else
      "#{@account.name} is at #{@usage.percent_used}% of its monthly events"
    end
  end
end
