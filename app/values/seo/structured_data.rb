module Seo
  # A schema.org graph, ready to be serialised into a JSON-LD script block.
  #
  # WHY THE PAYLOAD IS A BARE ARRAY OF HASHES, when CLAUDE.md §3 says value
  # objects are typed and hashes do not cross service boundaries. JSON-LD is not
  # our data structure — it is a wire format defined by somebody else, deeply
  # nested, heterogeneous by node type, and read by consumers who will accept
  # extra keys and ignore ones they do not know. Modelling each of `Offer`,
  # `Question`, `TechArticle` and `UnitPriceSpecification` as a Dry::Struct would
  # produce a dozen classes that exist only to be flattened back into hashes one
  # line later, and would still not validate anything a crawler cares about.
  #
  # So the boundary is drawn here instead: this struct is what crosses it, the
  # graph is opaque payload, and the guarantee the type system would have given
  # is provided by spec/services/seo/build_structured_data_spec.rb, which parses
  # the rendered JSON and asserts on node types and required fields. That is the
  # check that would have caught a real mistake; a wrapper class per node type is
  # not.
  class StructuredData < Dry::Struct
    attribute :graph, Types::Strict::Array.of(Types::Strict::Hash).constrained(min_size: 1)

    # One document with a @graph, rather than several sibling <script> blocks.
    # Both are valid and consumers handle both, but a single graph lets nodes
    # reference each other by @id — the FAQ page can say it is part of the same
    # WebSite the software belongs to — which several disconnected blocks cannot.
    def to_json_ld
      { "@context" => "https://schema.org", "@graph" => graph }
    end
  end
end
