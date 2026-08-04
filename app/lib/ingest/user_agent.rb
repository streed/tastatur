module Ingest
  # Reduces a user-agent string to five coarse, low-entropy facts — and then
  # throws the string away.
  #
  # FIVE, and #to_h is the list. This said "four" while returning five since it
  # was written, and app/views/compliance/privacy.html.erb copied the wrong
  # number onto a public page: the operating system's major version is a real
  # column and was simply never disclosed. It is major-version-only and entirely
  # defensible; not saying so was the defect. A field added here is a field that
  # page has to list.
  #
  # The UA string itself is never stored. A full user-agent is a strong
  # fingerprinting signal (often 10+ bits of entropy on its own); "Firefox /
  # 128 / macOS / desktop" is not. We keep only the major browser version for
  # the same reason: "128" is shared by millions of people, "128.0.6613.85" is
  # shared by far fewer.
  class UserAgent
    UNKNOWN = "Unknown".freeze

    # Anything the detector recognises as a bot is dropped at ingest and never
    # reaches the database. Crawler traffic is the single largest source of
    # inflated numbers in self-hosted analytics, and once it is written it is
    # indistinguishable from a real visitor.
    def self.parse(string)
      new(string)
    end

    def initialize(string)
      @raw = string.to_s
      @detector = DeviceDetector.new(@raw)
    end

    def bot?
      return true if @raw.blank?
      return true if @detector.bot?

      # DeviceDetector's list is excellent for declared crawlers but does not
      # catch headless automation that presents as a normal browser. These are
      # the markers that identify themselves honestly.
      HEADLESS_MARKERS.any? { |marker| @raw.include?(marker) }
    end

    HEADLESS_MARKERS = %w[HeadlessChrome Headless PhantomJS Puppeteer Playwright Prerender].freeze
    private_constant :HEADLESS_MARKERS

    def browser
      @detector.name.presence || UNKNOWN
    end

    # Major version only. See the class comment.
    def browser_version
      @detector.full_version.to_s.split(".").first.presence
    end

    def os
      @detector.os_name.presence || UNKNOWN
    end

    def os_version
      @detector.os_full_version.to_s.split(".").first.presence
    end

    # DeviceDetector reports a richer taxonomy (smartphone, phablet, console,
    # tv...). We flatten it to three buckets because that is the granularity a
    # site owner actually acts on, and because rare device types are
    # identifying in a small audience.
    def device_type
      case @detector.device_type
      when "smartphone", "phablet", "feature phone" then "mobile"
      when "tablet"                                  then "tablet"
      else "desktop"
      end
    end

    def to_h
      {
        browser: browser,
        browser_version: browser_version,
        os: os,
        os_version: os_version,
        device_type: device_type
      }
    end
  end
end
