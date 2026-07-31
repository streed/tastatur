# Supplies the goal and funnel-step forms with the values this site has really
# recorded, so a match target can be picked instead of typed.
#
# A helper method rather than a before_action, and that is the whole point of
# the concern: Analytics::KnownValues scans thirty days of raw events, and a
# successful create or update redirects without ever rendering a form. A
# callback would pay for that scan on every save. This pays for it only when a
# template actually asks.
#
# Requires @site to be set, which both including controllers do first.
module OffersKnownValues
  extend ActiveSupport::Concern

  # The DOM id of the single JSON payload on the page. The forms render it once
  # and every picker on the page points at it by id — a funnel holds up to eight
  # pickers and the payload can run to hundreds of paths, so a copy per field
  # would put the same tens of kilobytes on the page nine times.
  KNOWN_VALUES_DOM_ID = "known-values".freeze

  included do
    helper_method :known_values
  end

  def known_values
    @known_values ||= Analytics::KnownValues.call(site: @site).value!
  end
end
