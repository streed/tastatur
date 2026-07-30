module Analytics
  # k-anonymity for any table of (value, visitors) rows.
  #
  # This lives on its own rather than inside Analytics::Breakdown because there
  # is now more than one kind of breakdown — dimensions and custom event
  # properties — and a second copy of this rule is exactly the mistake that
  # turns a privacy guarantee into a privacy claim. Property values are the
  # higher-risk of the two: a customer chooses the keys, so `plan` and `user_id`
  # and `email_domain` are all equally likely to arrive, and a property panel is
  # the first place in this codebase where a breakdown row could be a single
  # person by construction rather than by coincidence.
  #
  # Callers pass rows as hashes with a "visitors" key, which is the shape every
  # aggregate query here already returns.
  module Suppression
    module_function

    # Rows seen by fewer than k distinct visitors are withheld.
    #
    # The argument: a breakdown row is a statement that "someone who did X also
    # did Y". When only two people in Liechtenstein visited a niche page, that
    # row plus a rough visit time is enough for someone with outside knowledge
    # to work out who. At k=25 the row describes a crowd rather than a person.
    #
    # COMPLEMENTARY SUPPRESSION. Hiding the small rows is not sufficient on its
    # own. If exactly one row falls below the threshold, then
    #
    #     that row's value = reported total − sum of the visible rows
    #
    # and the suppression has protected nothing. The standard fix from
    # statistical disclosure control is to suppress a second row as well — the
    # smallest surviving one — so the withheld total covers at least two rows
    # and cannot be attributed to either. It costs one row of usefulness and is
    # the difference between suppression that works and suppression that only
    # looks like it does.
    #
    # Returns [kept, withheld].
    def partition(rows, threshold:)
      return [rows, []] if threshold.to_i.zero?

      kept, withheld = rows.partition { |row| row["visitors"].to_i >= threshold }

      if withheld.one? && kept.any?
        smallest = kept.min_by { |row| row["visitors"].to_i }
        kept -= [smallest]
        withheld += [smallest]
      end

      [kept, withheld]
    end
  end
end
