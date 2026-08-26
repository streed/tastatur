module Passwords
  # Passwords this instance will not accept, however long they are.
  #
  # WHY A LIST AND NOT JUST A LENGTH RULE. The sign-in form is already about as
  # well defended against guessing as it can be: Rack::Attack allows five
  # attempts per twenty seconds by client AND by address, Devise's lockable
  # steps in after that, and the digest is bcrypt at cost 12. None of it touches
  # the attack that actually takes accounts, which is credential stuffing — the
  # attacker already HAS the password, from somewhere else, and is only checking
  # which account it opens. A rate limit cannot help with a first guess that is
  # correct.
  #
  # WHY OFFLINE. The obvious alternative is Have I Been Pwned's range API, which
  # is genuinely well designed — it sends five hex digits of a SHA-1 and gets a
  # bucket back. It is still a request, made at the moment somebody types a
  # password, telling a third party that an account here is being created with a
  # password in a particular bucket. §13 spends a great deal of effort not
  # sending far less than that anywhere, and a file read is not a hard thing to
  # arrange. It also means password changes keep working when somebody else's
  # API is down, which matters most during exactly the incident that makes
  # everybody change their password at once.
  #
  # THE BUNDLED LIST IS SHORT AND THAT IS ADMITTED RATHER THAN HIDDEN. It is the
  # head of the distribution, not real coverage. COMMON_PASSWORD_LIST points at
  # a bigger file — SecLists' top-100k is the usual one — and the format is one
  # password per line so that file needs no conversion. A quarter of a million
  # lines costs a few megabytes of resident memory once, at boot.
  module DenyList
    BUNDLED_LIST = Rails.root.join("config/common_passwords.txt")

    # Below this many DISTINCT characters a password is a pattern rather than a
    # secret, whatever its length: "aaaaaaaaaaaa", "121212121212",
    # "abababababab" all clear a twelve-character minimum and none of them is
    # worth more than a handful of guesses.
    MIN_DISTINCT_CHARACTERS = 5

    # A run of characters adjacent in the alphabet or on the number row, in
    # either direction. Six is short enough to catch "123456" inside a longer
    # string and long enough not to fire on an ordinary word.
    SEQUENCE_LENGTH = 6

    class << self
      def refuses?(candidate)
        value = candidate.to_s.strip.downcase
        return false if value.empty?

        listed?(value) || too_few_distinct_characters?(value) || sequential?(value)
      end

      # Separate from `refuses?` because the caller knows the user and this does
      # not. A password containing the address it signs in with is one leaked
      # address away from being guessable, and it is a mistake people make
      # deliberately, believing it memorable rather than obvious.
      def echoes?(candidate, user)
        value = candidate.to_s.downcase
        return false if value.empty?

        identifiers_for(user).any? { |part| value.include?(part) }
      end

      def entries
        @entries ||= load_entries
      end

      # For the spec, and for a console session checking what a deployment
      # actually loaded.
      def reload!
        @entries = nil
        entries
      end

      def source
        ENV["COMMON_PASSWORD_LIST"].presence || BUNDLED_LIST.to_s
      end

      private

      # A Set, because this is a membership test run on a form submission and a
      # linear scan of a hundred thousand strings is not.
      #
      # A missing or unreadable file is a WARNING, not a raise. An operator who
      # pointed COMMON_PASSWORD_LIST at a path that does not exist has made a
      # configuration mistake, and the right response is a loud log line and a
      # weaker check — not an instance where nobody can register or reset a
      # password. Failing closed here would take the whole sign-up flow down
      # over a typo in a hardening setting.
      def load_entries
        path = Pathname.new(source)
        unless path.exist? && path.readable?
          Rails.logger.warn(
            "[tastatur] COMMON_PASSWORD_LIST is set to #{source}, which cannot be read. " \
            "Common-password refusal is disabled until it can."
          )
          return Set.new
        end

        path.each_line.filter_map { |line|
          value = line.strip.downcase
          value unless value.empty? || value.start_with?("#")
        }.to_set
      end

      def listed?(value)
        entries.include?(value)
      end

      def too_few_distinct_characters?(value)
        value.chars.uniq.length < MIN_DISTINCT_CHARACTERS
      end

      # Walks the string once, counting how far the current ±1 run extends.
      # `abcdef`, `654321` and `qwerty` are all caught — the last because the
      # bundled list holds the keyboard rows, which are runs on a layout rather
      # than in the character set and cannot be derived arithmetically.
      def sequential?(value)
        run = 1

        value.each_char.each_cons(2) do |a, b|
          step = b.ord - a.ord
          run = step == 1 || step == -1 ? run + 1 : 1
          return true if run >= SEQUENCE_LENGTH
        end

        false
      end

      # The parts of somebody's own identity that must not appear inside their
      # password. Short fragments are dropped: refusing every password
      # containing a three-letter name would refuse a great many good ones.
      def identifiers_for(user)
        return [] if user.nil?

        local_part = user.email.to_s.split("@").first
        domain = user.email.to_s.split("@").last.to_s.split(".").first

        [local_part, domain, user.try(:name)].compact_blank
                                             .map { |part| part.to_s.downcase.strip }
                                             .select { |part| part.length >= 4 }
      end
    end
  end
end
