module Admin
  class DashboardController < BaseController
    def show
      @summary = Admin::InstanceSummary.call.value!
    end
  end
end
