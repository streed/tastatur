module Analytics
  # A date range plus the bucket size a chart should use for it.
  #
  # Everything is stored in UTC and displayed in the site's reporting timezone.
  # The conversion happens exactly once, here, by resolving the preset against
  # the site's zone and handing UTC boundaries to SQL — so no query anywhere
  # else has to think about timezones, and "today" means the site owner's
  # today rather than the server's.
  class Period
    PRESETS = {
      "today" => "Today",
      "yesterday" => "Yesterday",
      "7d" => "Last 7 days",
      "30d" => "Last 30 days",
      "90d" => "Last 90 days",
      "12mo" => "Last 12 months",
      "month" => "This month",
      "custom" => "Custom range"
    }.freeze

    DEFAULT = "30d".freeze

    attr_reader :key, :from, :to, :zone

    def self.parse(key, site:, from: nil, to: nil)
      new(key, site: site, from: from, to: to)
    end

    def initialize(key, site:, from: nil, to: nil)
      @key = PRESETS.key?(key.to_s) ? key.to_s : DEFAULT
      @zone = ActiveSupport::TimeZone[site.timezone] || ActiveSupport::TimeZone["Etc/UTC"]
      @custom_from = from
      @custom_to = to
      resolve!
    end

    def label
      return "#{@from.in_time_zone(zone).to_date} – #{(@to - 1.second).in_time_zone(zone).to_date}" if key == "custom"

      PRESETS[key]
    end

    def days
      ((to - from) / 1.day).ceil
    end

    # Bucket width for the timeseries chart. Chosen so a chart never has fewer
    # than a handful of points or more than a couple of hundred.
    def interval
      case days
      when 0..2   then "hour"
      when 3..90  then "day"
      when 91..400 then "week"
      else "month"
      end
    end

    def postgres_interval
      { "hour" => "1 hour", "day" => "1 day", "week" => "7 days", "month" => "1 month" }.fetch(interval)
    end

    # Sub-day ranges are answered from the raw hypertable rather than the daily
    # aggregates, which cannot resolve finer than a day. See
    # docs/architecture/aggregates.md.
    def sub_daily?
      interval == "hour"
    end

    # The immediately preceding window of the same length, for "vs previous
    # period" comparisons.
    def previous
      span = to - from
      self.class.allocate.tap do |period|
        period.instance_variable_set(:@key, key)
        period.instance_variable_set(:@zone, zone)
        period.instance_variable_set(:@from, from - span)
        period.instance_variable_set(:@to, from)
      end
    end

    def to_param
      return { period: key, from: from.to_date.iso8601, to: (to - 1.second).to_date.iso8601 } if key == "custom"

      { period: key }
    end

    private

    def resolve!
      now = Time.current.in_time_zone(zone)

      # Upper bounds are EXCLUSIVE and land exactly on midnight rather than on
      # 23:59:59.999999. Every query uses `< to`, and Scope needs the boundary
      # to be exact to decide whether a continuous aggregate's buckets line up
      # with the requested range.
      tomorrow = now.beginning_of_day + 1.day

      @from, @to =
        case key
        when "today"     then [now.beginning_of_day, tomorrow]
        when "yesterday" then [now.beginning_of_day - 1.day, now.beginning_of_day]
        when "7d"        then [now.beginning_of_day - 6.days, tomorrow]
        when "30d"       then [now.beginning_of_day - 29.days, tomorrow]
        when "90d"       then [now.beginning_of_day - 89.days, tomorrow]
        when "12mo"      then [(now - 11.months).beginning_of_month, tomorrow]
        when "month"     then [now.beginning_of_month, tomorrow]
        when "custom"    then custom_range(now)
        end

      @from = @from.utc
      @to = @to.utc
    end

    def custom_range(now)
      start_date = Date.parse(@custom_from.to_s)
      end_date = Date.parse(@custom_to.to_s)
      start_date, end_date = end_date, start_date if end_date < start_date

      # Guard rail: an unbounded custom range is an unbounded table scan.
      end_date = start_date + 730 if (end_date - start_date).to_i > 730

      [zone.parse(start_date.to_s).beginning_of_day, zone.parse(end_date.to_s).beginning_of_day + 1.day]
    rescue Date::Error, TypeError
      [now.beginning_of_day - 29.days, now.beginning_of_day + 1.day]
    end
  end
end
