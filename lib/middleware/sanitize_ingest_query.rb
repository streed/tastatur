# Makes the ingest endpoints survive a query string Rails refuses to parse.
#
# WHY THIS IS MIDDLEWARE AND NOT A `rescue_from`.
#
# `GET /api/event?s=%` answered **400** with a full exception report in the log.
# The obvious fix, a `rescue_from ActionController::BadRequest` in the controller,
# does not work, and it is worth writing down why: `ActionController::Instrumentation`
# builds its log payload from `filtered_parameters` at the top of `process_action`,
# which parses the query string *before* the rescuable block is entered. The
# exception escapes the controller entirely and no hook inside it can see it.
# Rack::Attack reads `params` in its throttle blocks even earlier.
#
# The ingest endpoint promises to be indistinguishable whatever you send it (see
# docs/architecture/ingest.md). A 400 breaks that promise, tells a prober their
# input was interesting, and puts an error in a stranger's browser console on a
# customer's site about a decision they cannot act on from there.
#
# So the bad input is neutralised before anything looks at it. Individual
# unparseable pairs are dropped and the rest of the query string is kept, because
# a POST can carry a perfectly good JSON body alongside a junk query string and
# that event should still be recorded.
#
# Scoped to the two ingest paths on purpose. Everywhere else a malformed query
# string is a client bug and a 400 is the correct, informative answer.
#
# Lives in lib/ and is required explicitly rather than autoloaded: the middleware
# stack is assembled while config/application.rb is still being evaluated, before
# Zeitwerk is set up, and Rails 8 needs the class itself — passing a String raises
# `undefined method 'name' for an instance of String`. `lib/middleware` is
# excluded from autoload_lib so this require is not fighting Zeitwerk over who
# owns the constant.
module Middleware
  class SanitizeIngestQuery
    PATHS = %w[/api/event /api/pixel].freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      query = env["QUERY_STRING"]

      if PATHS.include?(env["PATH_INFO"]) && !query.nil? && !query.empty? && !parses?(query)
        env["QUERY_STRING"] = salvage(query)
      end

      @app.call(env)
    end

    private

    # Keeps the pairs that parse on their own and drops the ones that do not. If
    # the result still will not parse — an over-deep nesting is a property of the
    # whole string rather than of one pair — the query string is abandoned.
    def salvage(query)
      kept = query.split("&").select { |pair| parses?(pair) }.join("&")

      parses?(kept) ? kept : ""
    end

    # Parses exactly the way the rest of the stack will, so this cannot disagree
    # with it. Anything raised here means "downstream would have answered 400".
    def parses?(query)
      ActionDispatch::ParamBuilder.from_query_string(query)
      true
    rescue StandardError
      false
    end
  end
end
