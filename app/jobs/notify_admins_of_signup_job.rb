class NotifyAdminsOfSignupJob < ApplicationJob
  # Not `within_5_seconds`. That tier is for mail somebody is actively waiting on
  # — a confirmation link with a signup form still open behind it — and it is
  # drained first, so putting an administrator's FYI there would let a burst of
  # signups queue in front of the confirmation emails those same signups need.
  #
  # Nobody is waiting for this one.
  queue_as :within_5_minutes

  def perform(user_id)
    Admin::NotifyNewSignup.call(user_id: user_id)
  end
end
