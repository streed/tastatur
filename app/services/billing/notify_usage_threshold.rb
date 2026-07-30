module Billing
  # Tells an account it is close to, or past, its monthly event allowance.
  #
  # A quota nobody is warned about is indistinguishable from a bug. The visible
  # symptom of hitting the cap is "my numbers stopped moving", which is exactly
  # what a broken installation looks like — so the customer's first assumption is
  # that we are broken, and they are right to think so if we never said anything.
  #
  # ONCE PER LEVEL PER MONTH. The check runs hourly, so the guard is a Redis key
  # claimed with SET NX: whoever creates it sends the mail, and everyone after it
  # does not. A boolean column on accounts would need clearing on the first of the
  # month by something, and that something is another scheduled job that can fail
  # silently. A key whose name contains the month cannot fail to reset.
  class NotifyUsageThreshold < ApplicationService
    # Most severe first: an account that has blown straight past its cap between
    # two hourly checks gets the message that matters, not the one about getting
    # close.
    LEVELS = %w[exceeded approaching].freeze

    # Outlives the month it refers to, so a late-in-the-month notice cannot be
    # re-sent by a job running on the 1st with a stale clock.
    NOTICE_TTL = 62.days

    # OWNERS ONLY, because the email's whole point is a button that changes the plan
    # and AccountPolicy#manage_billing? is owner-only.
    #
    # It used to include admins, on the reasoning that members and viewers cannot
    # change the plan — which is true of admins too. The result was a mail whose
    # primary action bounced them off /billing with "you do not have access to
    # that". Either the email or the policy had to give; the policy is the one
    # protecting a recurring charge, so it stays and the recipient list narrows.
    #
    # An admin is not left in the dark: the site settings screen shows refused
    # events with an explanation, and so does the installation screen.
    NOTIFIED_ROLES = %w[owner].freeze

    def initialize(account:, at: Time.current)
      @account = account
      @at = at
    end

    def call
      snapshot = MeasureUsage.call(account: @account, at: @at).value!

      level = level_for(snapshot)
      return Failure(:within_limits) if level.nil?
      return Failure(:already_notified) unless claim!(level)

      # The claim is released if enqueuing fails, for the same reason
      # Billing::ApplyStripeEvent releases its receipt: the key means the warning was
      # SENT, and holding it for a warning that was not sent suppresses it for the
      # rest of the month. `deliver_later` writes to Redis and can raise, and the
      # whole point of this email is that an account whose events stop being recorded
      # is told rather than left to conclude the product is broken.
      begin
        recipients.each do |user|
          BillingMailer.usage_threshold(@account, user, level).deliver_later
        end
      rescue StandardError
        release!(level)
        raise
      end

      Rails.logger.info("[tastatur] usage notice (#{level}) for account #{@account.id}")
      Success(level)
    end

    private

    def level_for(snapshot)
      return nil if snapshot.unlimited_events?
      return "exceeded" if snapshot.exceeded?
      return "approaching" if snapshot.approaching_limit?

      nil
    end

    def recipients
      @account.memberships.where(role: NOTIFIED_ROLES).includes(:user).map(&:user).uniq
    end

    # SET key 1 NX EX ttl -> true when this call created it. The atomicity is the
    # whole guarantee: two workers reconciling the same account concurrently both
    # see "exceeded", and exactly one of them gets true back.
    def claim!(level)
      REDIS_POOL.with { |redis| redis.set(notice_key(level), 1, nx: true, ex: NOTICE_TTL.to_i) }
    end

    def release!(level)
      REDIS_POOL.with { |redis| redis.del(notice_key(level)) }
    end

    def notice_key(level)
      "tastatur:usage_notice:#{@account.id}:#{UsageMeter.period_key(@at)}:#{level}"
    end
  end
end
