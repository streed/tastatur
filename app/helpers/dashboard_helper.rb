module DashboardHelper
  # Filter and period state lives entirely in the URL. That is what makes a
  # filtered dashboard shareable, bookmarkable, and survivable across a browser
  # back button — and it means Turbo Frames can refresh a panel by fetching a
  # URL rather than by holding client-side state.
  def dashboard_url_for(site, period: nil, filters: nil, **overrides)
    period ||= @period
    filters ||= @filters

    site_path(site, **period.to_param, **filters.to_param.symbolize_keys, **overrides)
  end

  # The preset key travels with the event because it is our own vocabulary —
  # "7d", "12mo" — and says nothing about the site being looked at. The dates it
  # resolves to would be no more revealing, but they would also answer a question
  # nobody asked.
  def period_link(site, key, label)
    active = @period.key == key

    link_to label,
            dashboard_url_for(site, period: Analytics::Period.parse(key, site: site)),
            class: "segment", "aria-current": active.to_s,
            data: { analytics_event: "Period Changed",
                    analytics_props: { period: key, view: "dashboard" } }
  end

  # Clicking a breakdown row filters the whole dashboard by that value.
  def drill_down_url(site, dimension, value)
    dashboard_url_for(site, filters: @filters.with(dimension, value))
  end

  def remove_filter_url(site, dimension)
    dashboard_url_for(site, filters: @filters.without(dimension))
  end

  # One stat-tile value, formatted the way the default dashboard's stat row
  # formats the same metric. The widget speaks its own vocabulary (see
  # DashboardWidget::METRIC_READERS); this is the display half of that table.
  def stat_widget_value(metrics, metric)
    case metric
    when "visitors" then metric_number(metrics.visitors)
    when "pageviews" then metric_number(metrics.pageviews)
    when "visits" then metric_number(metrics.sessions)
    when "bounce_rate" then "#{metrics.bounce_rate}%"
    when "visit_duration" then metrics.formatted_duration
    end
  end

  # The filters a dashboard's author saved onto a widget, as one quiet line
  # under the card. Stated on every widget that carries any, because a panel
  # titled "Top pages" that is silently pinned to one source misleads exactly
  # the person a curated dashboard was built for.
  def widget_filter_summary(widget)
    filters = widget.saved_filters
    return if filters.empty?

    filters.applied.map { |key, value| "#{filters.label_for(key)} is #{value}" }.join(" · ")
  end

  # The dimension choices for a widget's filter rows, each option tagged with
  # the known-values group its values would come from — "pageview" for paths,
  # "event" for custom event names, "other" for dimensions the picker has no
  # payload for (the combobox then behaves as a plain text field).
  # value_picker_controller reads the group off the selected option.
  def filter_dimension_choices
    Analytics::Filters::HUMAN_LABELS.map do |key, label|
      group = case key
      when "page", "entry_page" then "pageview"
      when "event" then "event"
      else "other"
      end
      [label, key, { data: { group: group } }]
    end
  end

  # The turbo-frame a widget lives in, and the reason it is not `dom_id`:
  # `dom_id(widget)` is built from the primary key, and §10 keeps sequential
  # integers out of anything a page hands to a reader. Both the widget and the
  # panel that replaces it name this frame, so it is derived in one place.
  def widget_frame_id(widget)
    "widget-#{widget.public_id}"
  end

  # The delete confirm says what else the deletion revokes: share links
  # pointing at this dashboard are destroyed with it — deliberately, rather
  # than widened back to the default dashboard (see Dashboard#shared_links).
  def delete_dashboard_confirmation(dashboard)
    count = dashboard.shared_links.count
    return "Delete this dashboard?" if count.zero?

    "Delete this dashboard? #{pluralize(count, 'share link')} showing it will stop working."
  end

  # What we record about a filter interaction in our OWN analytics.
  #
  # For the sixteen fixed dimensions this is just the key — "page", "source" —
  # which is our vocabulary and says nothing about the site being looked at. A
  # custom event property key is not: the customer chose it, and `user_id`,
  # `workspace` or `email_domain` are all as likely to arrive as `plan`. The
  # whole argument for this product is that we do not put a customer's own
  # schema in an analytics database, so every property collapses to the constant
  # "property" — enough to learn that the panels get used, and nothing else.
  def analytics_dimension(key)
    Analytics::Filters.property?(key) ? "property" : key.to_s
  end

  def metric_number(value)
    return number_with_delimiter(value) if value < 100_000

    number_to_human(value, units: { thousand: "K", million: "M" }, format: "%n%u", precision: 3)
  end

  # What the volume tile and series are called. Under an event filter the
  # numbers ARE the matching events (see Analytics::Scope#volume_expression) —
  # a dashboard scoped to `event=Signup` contains no pageviews to count, and
  # labelling the events "Pageviews" would misreport them as badly as the zero
  # it replaces. Nil-safe because the public shared dashboard renders the same
  # partial with no filters at all.
  def volume_label(filters)
    filters&.event_scoped? ? "Events" : "Pageviews"
  end

  # Renders the "vs previous period" delta. Returns nil when there is nothing
  # honest to compare against — a jump from zero has no meaningful percentage.
  def delta_tag(metrics, metric, lower_is_better: false)
    change = metrics.change(metric)
    return tag.span("—", class: "stat-delta text-muted") if change.nil?

    improving = lower_is_better ? change.negative? : change.positive?
    direction = change.zero? ? "flat" : (improving ? "up" : "down")
    arrow = change.positive? ? "↑" : (change.negative? ? "↓" : "→")

    tag.span("#{arrow} #{change.abs}%", class: "stat-delta", data: { direction: direction },
                                        title: "vs previous #{@period.label.downcase}")
  end

  def country_name(code)
    return "Unknown" if code.blank?

    ISO3166::Country[code]&.common_name.presence || code
  end

  # Regional indicator symbols — the flag comes from the code itself, so there
  # is no image set to ship, cache-bust, or keep in sync with the country list.
  def country_flag(code)
    return "" unless code.to_s.match?(/\A[A-Za-z]{2}\z/)

    code.upcase.codepoints.map { |c| (c + 0x1F1A5).chr("UTF-8") }.join
  end

  # Rounds first, and carries into hours.
  #
  # Average duration arrives as a float from AVG(), so "45.30000000000001s" was
  # reachable, and anything over an hour rendered as "61m 40s" rather than
  # "1h 1m" — technically right and hard to read at a glance, which is the whole
  # job of this column.
  def duration_label(seconds)
    total = seconds.to_f.round
    return "0s" if total.zero?
    return "#{total}s" if total < 60

    minutes, secs = total.divmod(60)
    return "#{minutes}m #{secs}s" if minutes < 60

    hours, mins = minutes.divmod(60)
    "#{hours}h #{mins}m"
  end

  # `invalid_u` means nothing to anyone who has not read the contract. The tracker
  # uses one-letter keys to keep the beacon small, which is the right trade on the
  # wire and the wrong one in a diagnostic.
  INGEST_FIELD_NAMES = {
    "s" => "site token",
    "u" => "page URL",
    "n" => "event name",
    "r" => "referrer",
    "w" => "screen width",
    "p" => "properties",
    "c" => "currency",
    "v" => "revenue"
  }.freeze

  def ingest_field_name(reason)
    key = reason.to_s.delete_prefix("invalid_")

    INGEST_FIELD_NAMES.fetch(key, key.humanize.downcase)
  end

  # Why an event was refused, in words, plus what to do about it.
  #
  # Ingest::RejectionCounter records reasons as free-form strings and reads them
  # back by discovery rather than from a list — a deliberate fix for an earlier
  # version that iterated a hardcoded pair and therefore counted contract failures
  # into Redis and never showed them. The settings page then reintroduced the same
  # bug in the view layer by naming two reasons and rendering nothing for anything
  # else, so a new reason would make the "Rejected events" card appear showing two
  # zeroes and no explanation.
  #
  # So the labels live here, the view iterates whatever occurred, and an unmapped
  # reason still renders as a humanised name rather than vanishing.
  REJECTION_REASONS = {
    "hostname_mismatch" => {
      label: "Wrong hostname",
      note: "The page reported a hostname that is not this site's. Add it under extra hostnames " \
            "if it is yours."
    },
    "origin_mismatch" => {
      label: "Wrong origin",
      note: "The browser said the request came from another site. Usually the snippet has been " \
            "copied somewhere it does not belong."
    },
    "plan_limit" => {
      label: "Over plan limit",
      note: "This account has used its monthly event allowance, so these events were not recorded."
    }
  }.freeze

  def rejection_reason_label(reason)
    key = reason.to_s
    return "Malformed #{ingest_field_name(key)}" if key.start_with?("invalid_")

    REJECTION_REASONS.dig(key, :label) || key.humanize
  end

  def rejection_reason_note(reason)
    REJECTION_REASONS.dig(reason.to_s, :note)
  end

  # Minor units to a readable amount, with the currency named rather than
  # symbolised.
  #
  # No symbol lookup and no exchange rates on purpose. "$" is ambiguous across a
  # dozen currencies, and converting would mean picking a rate and a date and then
  # presenting the result as though it were measured. A three-letter code beside the
  # number is unambiguous and honest.
  #
  # Two decimal places suits most currencies and is wrong for the zero-decimal ones
  # (JPY, KRW, VND), so those are listed rather than guessed at.
  ZERO_DECIMAL_CURRENCIES = %w[BIF CLP DJF GNF JPY KMF KRW MGA PYG RWF UGX VND VUV XAF XOF XPF].freeze

  def money_amount(currency, cents)
    code = currency.to_s.upcase
    amount =
      if ZERO_DECIMAL_CURRENCIES.include?(code)
        number_with_delimiter(cents.to_i)
      else
        number_with_delimiter(format("%.2f", cents.to_i / 100.0))
      end

    "#{amount} #{code}"
  end
end
