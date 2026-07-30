module Billing
  # Stops a move to a smaller allowance mid-month from being retroactive, and
  # cleans up after itself on the way back up. Shared by the two places a plan
  # can change: Billing::SyncSubscription (Stripe said so) and Admin::ChangePlan
  # (an operator said so) — one implementation, so the two cannot drift.
  #
  # THE PROBLEM. The meter counts a whole calendar month and the plan sets the
  # ceiling that count is measured against. Dropping from Pro to Free on the 20th
  # therefore measures three million Pro-era events against Free's 100,000 and
  # refuses everything until the 1st — while /pricing promises that cancelling
  # leaves every site collecting, and that Free includes 100,000 events a month,
  # of which such an account would get none in the month it downgraded.
  #
  # So on a downgrade the ceiling becomes "what has been used already, plus the
  # new plan's full allowance", expiring at the end of the month. The customer
  # gets exactly the allowance they are now paying for, immediately.
  #
  # ONLY WHEN THE PLAN ACTUALLY CHANGES. Applying it on every sync would ratchet:
  # the nightly reconciliation would re-read "used" — now larger — and raise the
  # ceiling again, so the cap would recede forever.
  #
  # ASSIGNS BUT DOES NOT SAVE. Both callers follow with an `update!` that writes
  # the plan itself, and the override must land in the same write — a saved
  # override next to an unsaved plan change is a state no reader expects.
  class GrandfatherAllowance < ApplicationService
    def initialize(account:, plan:)
      @account = account
      @plan = plan
    end

    def call
      # Where billing is off there is no cap to grandfather, and event_limit is
      # UNLIMITED — which would read as "every plan is a downgrade" below.
      return Success(:unchanged) unless @account.billable?
      return Success(:unchanged) if @account.plan == @plan.key

      if @plan.unlimited_events? || @plan.monthly_event_limit >= @account.event_limit
        return Success(clear_expiring_override)
      end

      used = UsageMeter.used(@account.id)
      return Success(:unchanged) if used <= @plan.monthly_event_limit

      _, period_end = UsageMeter.period_bounds

      @account.event_limit_override = used + @plan.monthly_event_limit
      @account.event_limit_override_until = period_end

      Rails.logger.info(
        "[tastatur] account #{@account.id} downgraded to #{@plan.key} having used #{used} events this month; " \
        "allowing #{@account.event_limit_override} until #{period_end.to_date} so the month is not pre-spent"
      )

      Success(:granted)
    end

    private

    # An upgrade must not be capped by the grandfathering left over from an earlier
    # downgrade — an override of 3,100,000 would otherwise sit below Pro's ten
    # million and quietly become the real limit. Only overrides WITH an expiry are
    # cleared; one without is a deliberate support grant and is not ours to remove.
    def clear_expiring_override
      return :unchanged if @account.event_limit_override_until.nil?

      @account.event_limit_override = nil
      @account.event_limit_override_until = nil
      :cleared
    end
  end
end
