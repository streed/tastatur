module Analytics
  # The options the source / medium / campaign pickers offer on the builder.
  #
  # Two sources, and the difference between them is the point:
  #
  #   * every value this site has already SAVED on a link, whether or not
  #     anybody has clicked it. A link built ten minutes ago has no traffic and
  #     is exactly the one you are about to build a sibling of.
  #
  #   * every value that has ARRIVED, from the campaign report already on the
  #     page. Links get built in ad platforms and mail tools too, and those
  #     spellings are the ones a hand-typed link will fail to match.
  #
  # NO QUERY OF ITS OWN, deliberately. §9 requires a picker's options to come
  # through Analytics::Breakdown so the site's k-anonymity threshold applies to
  # them — a value offered in a form is as much a statement about visitors as a
  # row in a panel. Reading them off CampaignReport's surviving rows satisfies
  # that more strictly than a Breakdown call would (the tuple threshold is
  # tighter than any single column's) and costs nothing, where a second call
  # would be a second scan of the same raw events on the same page render.
  #
  # Saved values are not visitor data at all — they are the customer's own rows,
  # entered by the customer — so no threshold applies to them and they are
  # always offered.
  class CampaignValues
    # The keys are the picker's group names, which are also the column names, so
    # the view and value_picker_controller.js agree without a translation layer.
    GROUPS = %w[utm_source utm_medium utm_campaign].freeze

    Value = Struct.new(:value, :visitors, keyword_init: true) do
      # Short keys: the same shape Analytics::KnownValues emits, because the
      # same Stimulus controller reads both.
      def payload = { "v" => value, "n" => visitors }
    end

    def initialize(links:, report:)
      @links = links
      @report = report
    end

    def payload
      GROUPS.index_with { |group| values_for(group).map(&:payload) }
    end

    def any?
      GROUPS.any? { |group| values_for(group).any? }
    end

    private

    # Visitors are summed across the tuple rows a value appears in, which is
    # fine HERE and nowhere else on this screen: this is a sort key for a
    # dropdown, not a figure anybody reads as a visitor count. It over-counts a
    # visitor who arrived on two links of the same campaign, and ranking is all
    # it is used for. §8's rule is about numbers shown as unique counts.
    def values_for(group)
      @values ||= {}
      @values[group] ||= begin
        counts = Hash.new(0)

        @report.rows.each do |row|
          value = row.public_send(group).presence
          counts[value] += row.visitors if value
        end

        # Saved values, and the conventional mediums, land at zero rather than
        # being left out. `+= 0` rather than `||= 0` on purpose: the hash
        # defaults to 0, so `||=` reads the default, finds it truthy and never
        # writes the key at all.
        seeded_for(group).each { |value| counts[value] += 0 }

        counts.sort_by { |value, visitors| [-visitors, value] }
              .map { |value, visitors| Value.new(value: value, visitors: visitors) }
      end
    end

    # An account's first campaign link is built against an empty site: nothing
    # saved, nothing arrived, so every picker opens onto nothing on the one
    # screen where the vocabulary is being set for good. The conventional
    # mediums are ours to offer and describe no visitor, so they seed that one
    # group — source and campaign are the customer's own words and there is
    # nothing honest to put in them.
    def seeded_for(group)
      saved = @links.filter_map { |link| link.public_send(group).presence }
      return saved unless group == "utm_medium"

      saved + CampaignLink::COMMON_MEDIUMS
    end
  end
end
