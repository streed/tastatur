module Seo
  # One question and its answer.
  #
  # The answer is an array of PLAIN TEXT paragraphs, not HTML and not markdown,
  # because it has to render as all three: the HTML page wraps each in a <p>,
  # the markdown rendering joins them with blank lines, and the FAQPage JSON-LD
  # needs `acceptedAnswer.text`. Storing markup would mean one of those three
  # carrying the other's tags — an `<a href>` inside a JSON-LD answer, or a
  # literal <p> in the markdown — so links are a separate, structured field
  # instead and each renderer decides what a link looks like.
  class FaqEntry < Dry::Struct
    # A pointer to the page that says the same thing at length. `route` is the
    # NAME of a path helper rather than a path, so a link that outlives its route
    # fails in the view where somebody will see it, instead of rendering a 404 as
    # a working link. The set is a frozen catalogue, never user input — see
    # Seo::Faq.
    class Link < Dry::Struct
      attribute :label, Types::Strict::String
      attribute :route, Types::Strict::Symbol
    end

    attribute :anchor, Types::Strict::String
    attribute :question, Types::Strict::String
    attribute :answer, Types::Strict::Array.of(Types::Strict::String).constrained(min_size: 1)
    attribute :links, Types::Strict::Array.of(Link).default([].freeze)

    # The plain-text answer as one string, which is what schema.org's
    # acceptedAnswer wants and what an AI reader extracts.
    def answer_text
      answer.join("\n\n")
    end
  end
end
