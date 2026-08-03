# One of the things that satisfies a funnel step. A step matches when ANY of its
# conditions match, which is where a funnel gets its OR.
#
# Kind lives here rather than on the step, and that is the point: "Signed up" is
# routinely the /welcome pageview OR the Signup event, and a step that could only
# be one or the other forced that funnel to be split into two that cannot be
# added back together.
class FunnelStepCondition < ApplicationRecord
  KINDS = Goal::KINDS
  MATCH_TYPES = Goal::MATCH_TYPES

  belongs_to :funnel_step

  # Position is assigned by FunnelStep#renumber_conditions before validation, so
  # it is not user input and needs no uniqueness validation here — see the long
  # note in FunnelStep about why one on `position` actively broke removal.
  validates :position, numericality: { greater_than: 0 }
  validates :kind, inclusion: { in: KINDS }
  validates :match_type, inclusion: { in: MATCH_TYPES }
  validates :match_value, presence: true, length: { maximum: 500 }

  def pageview?
    kind == "pageview"
  end

  # The column this condition matches against in the events hypertable.
  def match_column
    pageview? ? :path : :event_name
  end

  def matcher
    Analytics::PathPattern.new(match_value, match_type: match_type)
  end

  # How the condition reads on a report. An event name is qualified because a
  # custom event called "/pricing" and the page /pricing are different things
  # and would otherwise be printed identically.
  def label
    pageview? ? match_value.to_s : "event: #{match_value}"
  end
end
