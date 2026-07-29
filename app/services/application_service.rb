# Base class for service objects.
#
# Usage:
#   class CreateOrder < ApplicationService
#     def initialize(user:, params:)
#       @user = user
#       @params = params
#     end
#
#     def call
#       order = @user.orders.build(@params)
#       return Failure(order.errors) unless order.save
#       Success(order)
#     end
#   end
#
#   case CreateOrder.call(user:, params:)
#   in Success(order) then ...
#   in Failure(errors) then ...
#   end
class ApplicationService
  include Dry::Monads[:result]

  def self.call(...)
    new(...).call
  end
end
