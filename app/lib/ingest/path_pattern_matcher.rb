module Ingest
  # Compiles a site's declared route templates into a segment trie, and uses it
  # to rewrite a concrete path's dynamic segments to their declared placeholders.
  #
  #   patterns: ["/sites/:token", "/player/:id", "/blog/:year/:month/:slug"]
  #   apply(["", "sites", "FB1WRC5D0PFFHKZ5"])  =>  ["", "sites", ":token"], 3
  #
  # WHY A TRIE and not a list of regexes. Route sets share prefixes — /sites,
  # /sites/:token, /sites/:token/edit — and a trie resolves the literal-vs-param
  # choice once per level instead of re-testing every pattern against every path.
  # It also gives the caller a clean "matched this far, you take it from here"
  # boundary (see #apply), which is what lets PathScrubber match a declared
  # prefix and hand the undeclared tail to its heuristics.
  #
  # MATCHING IS GREEDY AND DOES NOT BACKTRACK: at each segment a literal child
  # wins over the param child, and once neither matches, matching stops. Route
  # patterns are unambiguous per level in practice (you do not declare a literal
  # and a param that a single path could satisfy two different ways), and
  # backtracking would put allocation and recursion on the ingest hot path for a
  # case that does not occur. The behaviour is therefore predictable: the most
  # specific declared branch is followed as far as it goes.
  class PathPatternMatcher
    # A trie node: literal children keyed by exact segment, plus at most one
    # parameter child that matches any single segment and names it.
    Param = Struct.new(:placeholder, :node)

    class Node
      attr_reader :literals
      attr_accessor :param

      def initialize
        @literals = {}
      end

      def literal(segment)
        @literals[segment]
      end
    end

    # Compiled matchers are cached by their pattern list, because the list is
    # stable per site and this runs once per event on the ingest path. The set of
    # distinct pattern lists is bounded by the number of sites that use the
    # feature, so the cache does not grow without bound.
    @cache = Concurrent::Map.new

    class << self
      def for(patterns)
        # dup before freezing: `patterns` is often a live Site#path_patterns
        # array, and it must not be frozen out from under the caller. Equal
        # content still hits the same cache entry (Concurrent::Map compares by
        # value), so a fresh array per request does not defeat the cache.
        list = Array(patterns).dup.freeze
        @cache.compute_if_absent(list) { new(list) }
      end

      # Test seam: drop the compiled-matcher cache.
      def clear_cache!
        @cache = Concurrent::Map.new
      end
    end

    def initialize(patterns)
      @root = Node.new
      Array(patterns).each { |pattern| insert(pattern) }
    end

    def empty?
      @root.literals.empty? && @root.param.nil?
    end

    # Rewrites the leading segments that a declared pattern covers, returning the
    # rewritten segments and the count consumed. The caller scrubs the rest:
    # a path is only ever as declared as its owner made it, and the tail beyond
    # the last matched node is not the pattern's business.
    def apply(segments)
      node = @root
      out = []
      consumed = 0

      segments.each do |segment|
        if (child = node.literal(segment))
          node = child
        elsif (param = node.param)
          out << param.placeholder
          node = param.node
          consumed += 1
          next
        else
          break
        end

        out << segment
        consumed += 1
      end

      [out, consumed]
    end

    private

    def insert(pattern)
      node = @root

      segments(pattern).each do |segment|
        node =
          if param?(segment)
            (node.param ||= Param.new(segment, Node.new)).node
          else
            node.literals[segment] ||= Node.new
          end
      end
    end

    # Split the same way a real path is split in PathScrubber, so the leading
    # empty segment from the root "/" lines up on both sides.
    def segments(pattern)
      pattern.to_s.split("/")
    end

    def param?(segment)
      segment.start_with?(":")
    end
  end
end
