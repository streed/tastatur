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

  def period_link(site, key, label)
    active = @period.key == key

    link_to label,
            dashboard_url_for(site, period: Analytics::Period.parse(key, site: site)),
            class: "segment", "aria-current": active.to_s
  end

  # Clicking a breakdown row filters the whole dashboard by that value.
  def drill_down_url(site, dimension, value)
    dashboard_url_for(site, filters: @filters.with(dimension, value))
  end

  def remove_filter_url(site, dimension)
    dashboard_url_for(site, filters: @filters.without(dimension))
  end

  def metric_number(value)
    return number_with_delimiter(value) if value < 100_000

    number_to_human(value, units: { thousand: "K", million: "M" }, format: "%n%u", precision: 3)
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
