# A period plus dimension filters. The filter keys are exactly
# `Analytics::Filters::DIMENSIONS`, declared from it rather than copied, so a
# dimension added there is accepted here without anyone remembering to.
class McpReportContract < McpPeriodContract
  json do
    optional(:filters).hash do
      Analytics::Filters::DIMENSIONS.each_key { |name| optional(name.to_sym).filled(:string) }
    end
    optional(:compare).filled(:bool)
  end
end
