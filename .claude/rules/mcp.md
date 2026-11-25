---
paths:
  - "app/controllers/mcp_controller.rb"
  - "app/services/mcp/**/*.rb"
  - "app/lib/mcp/**/*.rb"
  - "app/contracts/mcp_*.rb"
  - "app/values/mcp/**/*.rb"
  - "app/controllers/sites/mcp_controller.rb"
  - "app/policies/api_key_policy.rb"
  - "spec/requests/mcp_setup_spec.rb"
  - "spec/requests/mcp_spec.rb"
---

### 21. The MCP server: an LLM agent reading one site's analytics

`POST /mcp` speaks Model Context Protocol (Streamable HTTP, stateless JSON-RPC, no
SSE, no sessions; `GET` is 405). Authenticated by an `ApiKey` holding
`read:analytics`. Tools live in `app/services/mcp/tools/`, one per file, each a thin
wrapper over an existing `Analytics::` / `Revenue::` service.

- **Scopes are the security boundary.** `ApiKey#scopes` is `write:identify` or
  `read:analytics`, never both by default and with no "all". Every
  `Api::V1::BaseController` subclass MUST set `required_scope`; one that forgets
  raises, so a new endpoint cannot quietly accept any key. The key handed to an
  agent lives in the least controlled place a credential can, which is why it must
  not be the one that asserts "visitor X is user Y".
- **Any member may connect an agent; only an admin may make a key that writes.**
  `/sites/:token/mcp` (`Sites::McpController`) is open to every role including
  viewers, and it can only ever make `read:analytics` keys: the scope is fixed in
  the controller, not read from params. That is safe for three reasons that must
  all stay true: a read key grants nothing its maker cannot already see; it is
  **bound to its maker** (`api_keys.user_id`, cascade-deleted with the user) and
  `ApiKey.authenticate` re-checks their membership on every request, so removing
  someone from the organisation ends their agent's access with the same
  indistinguishable 401; and a member sees and revokes only their own keys
  (`ApiKeyPolicy::Scope`). Identify keys have NO owner on purpose — they belong to
  a deployment and must outlive the admin who made them. Do not bind them.
- **The site is never an argument.** The key names one site; every tool is built
  with it. Anything addressed by id (a funnel) is looked up THROUGH `site`.
- **No tool writes SQL.** k-anonymity, complementary suppression and the
  distinct-counts-are-not-additive rule (§8, §13) reach the agent only because it
  calls the same services as the dashboard. A tool that needs a new query needs a
  new service first. Withheld rows are reported as counts, never as values.
- **Bad arguments are errors, not defaults.** Unknown arguments and filter keys are
  refused (dry-schema would drop them silently and the report would run
  UNFILTERED while presented as filtered), and an unknown period preset is refused
  where `Period.parse` would fall back to 30 days. Argument errors return as
  `isError: true` tool results so the model can correct itself; only a malformed
  message or unknown tool is a JSON-RPC error.
- **Each result carries `notes`:** the caveats an analyst would state (do not sum
  `visitors` across buckets; `lifetime_revenue_cents` is a snapshot, §18). Add one
  when a tool exposes a figure with a trap.
- **Revenue is dark until `Tastatur.revenue_enabled?`.** An unavailable tool is
  neither listed nor callable (`Tool.available?`).
- **Throttled at 60/minute per key** (`mcp/key`), far below identify, because one
  breakdown scans the raw hypertable and the caller is a model in a loop.
- **Percentages are 0-100** and named `*_percent`; money is integer cents.
