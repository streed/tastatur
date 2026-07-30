module Admin
  # Tells the instance's administrators that somebody signed up.
  #
  # On a hosted instance this is the only signal that the product is being used
  # at all; on a self-hosted one with open registration it is how the operator
  # notices they are being signed up to by strangers.
  class NotifyNewSignup < ApplicationService
    def initialize(user_id:)
      @user_id = user_id
    end

    def call
      user = User.find_by(id: @user_id)
      # Deleted between enqueue and run. Not an error: the notification simply has
      # nothing to be about, and raising would retry a job that can never succeed.
      return Success(:user_gone) if user.nil?

      recipients = User.administrators.where.not(id: user.id)
      return Success(:no_administrators) if recipients.empty?

      recipients.find_each do |admin|
        AdminMailer.new_signup(admin: admin, user: user).deliver_later
      end

      Success(recipients.count)
    end
  end
end
