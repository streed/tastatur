# Public usage documentation.
#
# Public, and deliberately so: the most common reason someone reads these pages
# is to decide whether to use Tastatur at all, and putting the integration
# details behind a signup is a good way to lose that person. It also means a
# customer's developer can read them without needing an account on the
# customer's Tastatur.
#
# When a signed-in user views them, snippets are filled in with a real site
# token so they can be copied rather than adapted.
class DocsController < ApplicationController
  skip_before_action :authenticate_user!
  skip_after_action :verify_authorized

  # The site whose token appears in the examples. `policy_scope` still applies,
  # so this can never surface a token the viewer is not entitled to see, and it
  # is nil for anyone signed out.
  before_action :set_example_site

  # Readable before first-run setup: someone evaluating Tastatur should not have
  # to finish installing it to read how it works.
  always_reachable

  # HTML for people; markdown for machine readers, reached with
  # `Accept: text/markdown` or as /docs.md. Same content, same filled-in site
  # key, none of the layout — an agent reading the docs to write an integration
  # should not have to dig the snippets out of the page chrome.
  def show
    respond_to do |format|
      format.html
      format.md
    end
  end

  private

  def set_example_site
    return if current_user.nil? || current_account.nil?

    @example_site = policy_scope(Site).ordered.first
  end

  # `current_account` calls current_user.accounts, which is nil-safe, but
  # policy_scope needs a Pundit user even for a visitor.
  def pundit_user
    AuthorizationContext.new(user: current_user, account: current_user && current_account)
  end
end
