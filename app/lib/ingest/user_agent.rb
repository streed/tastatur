module Ingest
  # Reduces a user-agent string to four coarse, low-entropy facts — and then
  # throws the string away.
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

    # The browser half of the visitor HMAC, in place of the raw string.
    #
    # Ingest::Identifier used to hash the user-agent verbatim, which quietly
    # contradicted the reasoning at the top of this class: it exists because
    # "128.0.6613.85" identifies far fewer people than "128", and yet the digest
    # — the one value derived from the string that actually reaches the database
    # — was taking the whole thing. That went wrong in two directions.
    #
    # It SPLIT one person into several. Apple ships the full version
    # ("Version/17.2.1", "iPhone OS 17_2_1"), so an OS point update between two
    # visits on the same day minted a brand-new visitor for the same person.
    # Coarsening to the major version is the same fix, for the same reason, as
    # masking IPv6 to its /64.
    #
    # And it made the visitor count trivial to inflate. A user-agent is a header
    # the caller chooses, so one machine sending a random string per request
    # minted an unbounded number of distinct "visitors" on someone else's site.
    # Parsed first, garbage collapses into a single Unknown bucket and the space
    # reachable from one address is bounded by the tuples DeviceDetector emits.
    #
    # The cost, stated plainly: less entropy means more genuinely different
    # people behind one address hashing alike. Two phones on one wifi at the same
    # iOS version are now certainly one visitor rather than probably one. That is
    # the safe direction to be wrong in — it undercounts rather than inventing
    # people — and it is the trade the /64 mask already makes.
    #
    # 0x1f (unit separator) cannot occur in any component: browser and OS names
    # come from DeviceDetector's fixed vocabulary, the versions are digits, and
    # device_type is one of three literals. So the join is unambiguous and
    # browser "Chrome 1" cannot collide with browser "Chrome" at version "1".
    def fingerprint
      [browser, browser_version, os, os_version, device_type].join("\x1f")
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
