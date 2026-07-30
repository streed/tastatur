require "rails_helper"

RSpec.describe ChartHelper, type: :helper do
  Point = Analytics::Timeseries::Point

  let(:points) do
    [
      Point.new(bucket: Time.utc(2026, 7, 1), visitors: 10, pageviews: 20),
      Point.new(bucket: Time.utc(2026, 7, 2), visitors: 5, pageviews: 9),
      Point.new(bucket: Time.utc(2026, 7, 3), visitors: 0, pageviews: 0)
    ]
  end

  subject(:markup) { helper.timeseries_chart(points, interval: "day") }

  # `role="img"` plus an aria-label is the minimum and it is what this had: a
  # screen reader was told "visitors and pageviews over 3 intervals, peaking at 10"
  # and nothing else. That is a caption, not the data — someone who cannot see the
  # line could not answer "what happened on the 2nd", which is the only question a
  # chart exists to answer.
  describe "the text alternative" do
    it "keeps the summary label on the image itself" do
      expect(markup).to include('role="img"')
      expect(markup).to include("peaking at 10 visitors")
    end

    it "also carries every plotted point as a table" do
      expect(markup).to include("<table")
      expect(markup).to include("<caption>Visitors and pageviews per day</caption>")
    end

    it "labels each row with its bucket" do
      expect(markup).to include('scope="row"')
      expect(markup.scan('scope="row"').size).to eq(points.size)
      expect(markup).to include("1 Jul 2026")
    end

    it "includes the actual numbers, including the empty bucket" do
      expect(markup).to include("<td>10</td>").and include("<td>20</td>")
      expect(markup).to include("<td>5</td>").and include("<td>9</td>")
      expect(markup).to include("<td>0</td>")
    end

    it "names both series in the header" do
      expect(markup).to include('scope="col">Visitors<')
      expect(markup).to include('scope="col">Pageviews<')
    end

    # Removed from the visual flow, NOT from the accessibility tree. `display: none`
    # would hide it from screen readers too, which is the whole thing this is for.
    it "hides the table visually rather than semantically" do
      expect(markup).to include('class="sr-only"')
      expect(markup).not_to include("display: none")
      expect(markup).not_to include('aria-hidden="true"')
    end
  end

  it "says so plainly when there is nothing to plot" do
    expect(helper.timeseries_chart([], interval: "day")).to include("No data in this period")
  end

  # The y-axis used to be scaled to the pageviews series alone, so whenever a
  # bucket had more visitors than pageviews the visitors line was drawn above
  # the plot area and the viewBox clipped it to nothing. That is every bucket
  # on an event-filtered dashboard, where the whole chart rendered as empty.
  describe "the vertical scale" do
    let(:points) do
      [
        Point.new(bucket: Time.utc(2026, 7, 1), visitors: 14, pageviews: 0),
        Point.new(bucket: Time.utc(2026, 7, 2), visitors: 9, pageviews: 0)
      ]
    end

    it "covers the visitors series, not only pageviews" do
      # A clipped line shows up as a negative y coordinate in the path data.
      expect(markup).not_to match(/,-\d/)
    end

    it "draws axis ticks tall enough for the larger series" do
      expect(markup).to include(">20<")
    end
  end

  # "Pageviews" is only the right name for the volume series when the series
  # holds pageviews. Under an event filter it holds the matching events, and
  # every place the chart names the series follows.
  describe "the volume label" do
    subject(:markup) { helper.timeseries_chart(points, interval: "day", volume_label: "Events") }

    it "renames the series in the caption, header and description" do
      expect(markup).to include("<caption>Visitors and events per day</caption>")
      expect(markup).to include('scope="col">Events<')
      expect(markup).to include("Visitors and events over 3 intervals")
    end

    it "hands the label to the tooltip" do
      expect(markup).to include('data-volume-label="events"')
    end

    it "defaults to pageviews when not told otherwise" do
      expect(helper.timeseries_chart(points, interval: "day"))
        .to include("<caption>Visitors and pageviews per day</caption>")
    end
  end
end
