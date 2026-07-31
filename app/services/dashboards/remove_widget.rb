module Dashboards
  # Removes one widget from a dashboard, and closes the gap it leaves.
  #
  # The minimum is refused here rather than left to Dashboard#has_enough_widgets,
  # because that validation only runs when the DASHBOARD is saved — destroying a
  # child never consults it, so a dashboard would happily empty itself out and
  # then refuse every later rename with a message about widgets. "Delete the
  # dashboard instead" is the honest answer to someone removing the last one.
  #
  # Renumbering is not cosmetic. Positions carry a unique index, and
  # Dashboard#renumber_widgets rewrites them from scratch on any save that
  # touches the association — so a gap left here becomes a renumber later, at
  # the least convenient moment. Ascending order matters: assigning 3 => 2
  # before 4 => 3 means each target position has been vacated before anything
  # moves into it.
  class RemoveWidget < ApplicationService
    def initialize(widget:)
      @widget = widget
      @dashboard = widget.dashboard
    end

    def call
      return Failure(:last_widget) if @dashboard.dashboard_widgets.count <= Dashboard::MIN_WIDGETS

      @dashboard.transaction do
        @widget.destroy!
        renumber
      end

      Success(@dashboard)
    end

    private

    def renumber
      @dashboard.dashboard_widgets.reload.order(:position).each_with_index do |widget, index|
        widget.update_column(:position, index + 1) unless widget.position == index + 1
      end
    end
  end
end
