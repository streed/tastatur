module MarketingHelper
  # Miniature, non-interactive dashboard fragments for the marketing page.
  #
  # These are illustrations, not live data — the landing page is served to people
  # who have no account and no site, so there is nothing real to show. They are
  # built from the same tokens, the same validated palette and the same mark
  # specs as the real dashboard, so what a visitor sees here is what they get.
  #
  # The numbers are fixed rather than random: a landing page that renders
  # different figures on every reload looks like a mock-up, and a chart whose
  # shape changes per request cannot be reviewed.

  # A plausible month of traffic: weekly rhythm, gentle upward trend.
  SAMPLE_SERIES = [
    38, 44, 41, 52, 57, 31, 26, 49, 58, 54, 66, 71, 39, 33,
    62, 74, 69, 81, 88, 47, 41, 78, 91, 86, 99, 104, 58, 52, 96, 112
  ].freeze

  # Rendered as a filled area with a 2px line, exactly like the real chart, with
  # the axis and hover layer removed because at this size they would be noise.
  def mini_sparkline(series = SAMPLE_SERIES, width: 320, height: 64, color: "var(--color-signal)")
    max = series.max.to_f
    step = width.to_f / (series.size - 1)

    points = series.each_with_index.map do |value, i|
      [(i * step).round(2), (height - (value / max) * (height - 6) - 2).round(2)]
    end

    line = points.each_with_index.map { |(x, y), i| "#{i.zero? ? 'M' : 'L'}#{x},#{y}" }.join(" ")
    area = "#{line} L#{width},#{height} L0,#{height} Z"

    tag.svg(viewBox: "0 0 #{width} #{height}", class: "w-full h-auto block",
            role: "img", aria: { label: "Illustrative traffic chart" }) do
      safe_join([
        tag.path(d: area, fill: color, "fill-opacity": "0.10"),
        tag.path(d: line, fill: "none", stroke: color, "stroke-width": "2",
                 "stroke-linejoin": "round", "stroke-linecap": "round"),
        tag.circle(cx: points.last.first, cy: points.last.last, r: 3.5,
                   fill: color, stroke: "var(--color-surface)", "stroke-width": "2")
      ])
    end
  end

  # A compact bar table, same background-wash treatment as the real breakdowns.
  def mini_bar_rows(rows, accent: "var(--color-signal)")
    max = rows.map(&:last).max.to_f

    safe_join(
      rows.map do |label, value|
        tag.div(class: "relative flex items-center justify-between gap-3 px-2.5 py-1.5 text-[11px] isolate") do
          safe_join([
            tag.span(class: "absolute inset-y-0 left-0 -z-10",
                     style: "width: #{((value / max) * 100).round(1)}%; " \
                            "background: color-mix(in oklab, #{accent} 12%, transparent)"),
            tag.span(label, class: "truncate"),
            tag.span(number_with_delimiter(value), class: "num shrink-0 font-medium")
          ])
        end
      end
    )
  end

  def mini_stat(label, value, delta: nil, direction: "up")
    tag.div(class: "px-3 py-2.5") do
      safe_join([
        tag.p(label, class: "label text-[9px]"),
        tag.p(value, class: "text-[19px] font-semibold tracking-[-0.02em] leading-none mt-1.5"),
        delta ? tag.p(delta, class: "stat-delta text-[10px] mt-1", data: { direction: direction }) : nil
      ].compact)
    end
  end
end
