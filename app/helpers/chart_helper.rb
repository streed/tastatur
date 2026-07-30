module ChartHelper
  # Charts are rendered server-side as inline SVG.
  #
  # There is no charting library and no npm build step. That is a deliberate
  # fit with what this product is: a privacy tool should not ask its users to
  # load a third-party script bundle, and an analytics dashboard whose own page
  # pulls 300KB of JavaScript to draw a line is not making the argument it
  # claims to make. Inline SVG also means the chart is in the HTML — it renders
  # with JavaScript disabled, prints correctly, and can be read by a screen
  # reader through the table view.
  #
  # Mark specs follow the data-viz house style: 2px lines with round caps, a
  # ~10% area wash, hairline solid gridlines, and end markers with a 2px
  # surface ring so they stay legible where they cross the line.

  WIDTH = 960
  HEIGHT = 260
  PAD = { top: 16, right: 16, bottom: 26, left: 44 }.freeze

  SERIES = {
    visitors: { color: "var(--color-signal)", label: "Visitors" },
    pageviews: { color: "var(--color-petrol)", label: "Pageviews" }
  }.freeze

  # points: Array<Analytics::Timeseries::Point>
  def timeseries_chart(points, interval:)
    return content_tag(:p, "No data in this period.", class: "text-sm text-muted py-12 text-center") if points.blank?

    plot_w = WIDTH - PAD[:left] - PAD[:right]
    plot_h = HEIGHT - PAD[:top] - PAD[:bottom]

    max = [points.map(&:pageviews).max.to_i, 1].max
    ticks = axis_ticks(max)
    scale_max = [ticks.last, 1].max

    x = ->(i) { PAD[:left] + (points.size == 1 ? plot_w / 2.0 : (i.to_f / (points.size - 1)) * plot_w) }
    y = ->(v) { PAD[:top] + plot_h - ((v.to_f / scale_max) * plot_h) }

    tag.div(class: "relative", data: { controller: "chart" }) do
      safe_join([
        # Uniform scaling (the default "meet"), not preserveAspectRatio="none":
        # stretching the viewBox horizontally would squash the axis labels and
        # the end markers into ellipses. Scaling uniformly keeps text and marks
        # proportional at any container width.
        tag.svg(
          viewBox: "0 0 #{WIDTH} #{HEIGHT}",
          class: "w-full block h-auto",
          role: "img",
          aria: { label: chart_description(points) }
        ) do
          safe_join([
            gridlines(ticks, scale_max, x, y, plot_w),
            series_path(points, :pageviews, x, y, plot_h),
            series_path(points, :visitors, x, y, plot_h),
            hover_targets(points, x, plot_h)
          ])
        end,
        tooltip_element(points, interval),
        # The same numbers as a real table, visually hidden.
        #
        # `role="img"` with an aria-label is the minimum, and it is what this had:
        # it tells a screen reader "visitors and pageviews over 52 intervals,
        # peaking at 1,240" and then stops. That is a caption, not the data. Someone
        # who cannot see the line has no way to answer "what happened in March",
        # which is the only question the chart exists to answer.
        #
        # A table is the standard alternative and costs nothing to anyone else,
        # since it is removed from the visual flow rather than merely hidden —
        # `display: none` would take it out of the accessibility tree too.
        sr_only_data_table(points, interval)
      ])
    end
  end

  private

  # Round tick values so the axis reads 0 / 500 / 1,000 rather than 0 / 437 / 874.
  def axis_ticks(max, count: 4)
    magnitude = 10**Math.log10([max, 1].max).floor
    step = [1, 2, 2.5, 5, 10].map { |m| m * magnitude }.find { |s| (max.to_f / s) <= count } || magnitude * 10
    top = (max.to_f / step).ceil * step
    (0..(top / step).round).map { |i| (i * step).round }
  end

  def gridlines(ticks, scale_max, _x, y, plot_w)
    safe_join(
      ticks.map do |value|
        py = y.call(value)
        safe_join([
          tag.line(x1: PAD[:left], x2: PAD[:left] + plot_w, y1: py, y2: py,
                   class: value.zero? ? "baseline" : "gridline"),
          tag.text(number_to_human(value, units: { thousand: "k", million: "M" }, format: "%n%u"),
                   x: PAD[:left] - 8, y: py + 3, class: "axis-text", "text-anchor": "end")
        ])
      end
    )
  end

  def series_path(points, key, x, y, plot_h)
    values = points.map { |p| p.public_send(key) }
    line = values.each_with_index.map { |v, i| "#{i.zero? ? 'M' : 'L'}#{x.call(i).round(2)},#{y.call(v).round(2)}" }.join(" ")
    area = "#{line} L#{x.call(values.size - 1).round(2)},#{PAD[:top] + plot_h} L#{x.call(0).round(2)},#{PAD[:top] + plot_h} Z"
    color = SERIES[key][:color]

    last_index = values.size - 1

    safe_join([
      tag.path(d: area, fill: color, "fill-opacity": "0.10", stroke: "none"),
      tag.path(d: line, fill: "none", stroke: color, "stroke-width": "2",
               "stroke-linejoin": "round", "stroke-linecap": "round",
               "vector-effect": "non-scaling-stroke"),
      # End marker: r=4 (8px) with a 2px ring in the surface colour so it stays
      # readable where the two series cross.
      tag.circle(cx: x.call(last_index).round(2), cy: y.call(values[last_index]).round(2), r: 4,
                 fill: color, stroke: "var(--color-surface)", "stroke-width": "2")
    ])
  end

  # Invisible full-height bands, one per bucket — the hit target is the whole
  # column, not the 8px dot, so hovering is forgiving.
  def hover_targets(points, x, plot_h)
    band = points.size > 1 ? (x.call(1) - x.call(0)) : (WIDTH - PAD[:left] - PAD[:right])

    safe_join(
      points.each_with_index.map do |point, i|
        tag.rect(
          x: (x.call(i) - band / 2).round(2), y: PAD[:top], width: band.round(2), height: plot_h,
          fill: "transparent",
          data: {
            chart_target: "band", index: i,
            visitors: point.visitors, pageviews: point.pageviews
          }
        )
      end
    )
  end

  def tooltip_element(points, interval)
    labels = points.map { |p| bucket_label(p.bucket, interval) }

    tag.div(
      class: "pointer-events-none absolute hidden card px-3 py-2 text-xs z-10",
      data: { chart_target: "tooltip", labels: labels.to_json }
    )
  end

  def bucket_label(time, interval)
    case interval
    when "hour"  then time.strftime("%-d %b, %H:%M")
    when "week"  then "Week of #{time.strftime('%-d %b %Y')}"
    when "month" then time.strftime("%B %Y")
    else time.strftime("%a %-d %b %Y")
    end
  end

  def chart_description(points)
    "Visitors and pageviews over #{points.size} intervals, " \
      "peaking at #{points.map(&:visitors).max} visitors."
  end

  # Every plotted point, as a table, for anyone not reading the picture.
  def sr_only_data_table(points, interval)
    tag.div(class: "sr-only") do
      tag.table do
        safe_join([
          tag.caption("Visitors and pageviews per #{interval}"),
          tag.thead(tag.tr(safe_join([
            tag.th(interval.to_s.capitalize, scope: "col"),
            tag.th("Visitors", scope: "col"),
            tag.th("Pageviews", scope: "col")
          ]))),
          tag.tbody(safe_join(points.map do |point|
            tag.tr(safe_join([
              tag.th(bucket_label(point.bucket, interval), scope: "row"),
              tag.td(point.visitors),
              tag.td(point.pageviews)
            ]))
          end))
        ])
      end
    end
  end
end
