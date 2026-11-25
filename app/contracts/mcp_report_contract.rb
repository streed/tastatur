# A period plus dimension filters. The filter keys are exactly
# `Analytics::Filters::DIMENSIONS`, declared from it rather than copied, so a
# dimension added there is accepted here without anyone remembering to.
class McpReportContract < McpPeriodContract
  json do
    optional(:filters).hash do
      Analytics::Filters::DIMENSIONS.each_key { |name| optional(name.to_sym).filled(:string) }
      optional(:props).filled(:hash)
    end
    optional(:compare).filled(:bool)
  end

  # `props` is the one filter whose keys are the customer's own, so the schema
  # cannot name them. The constraints Analytics::Filters would otherwise apply by
  # SILENTLY dropping the offender are refused here instead: a property filter
  # that is dropped turns into a report that runs unfiltered and is presented as
  # filtered, which is the failure this contract exists to prevent.
  rule(filters: :props) do
    props = value
    next if props.nil?

    if props.size > Analytics::Filters::MAX_PROPERTY_FILTERS
      key.failure("takes at most #{Analytics::Filters::MAX_PROPERTY_FILTERS} properties")
    end

    props.each do |name, wanted|
      if name.to_s.strip.empty? || name.to_s.length > Analytics::Filters::MAX_PROPERTY_KEY
        key.failure("property names must be 1 to #{Analytics::Filters::MAX_PROPERTY_KEY} characters")
      elsif !wanted.is_a?(String) || wanted.empty?
        key.failure("#{name} must be a non-empty string")
      end
    end
  end
end
