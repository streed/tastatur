# Public-facing privacy documentation.
#
# These pages are deliberately not marketing pages. They are the honest,
# checkable account of what the software does, written so that a site owner can
# link to them from their own privacy policy and a data protection officer can
# read them without hitting a claim that falls apart under scrutiny.
#
# See docs/privacy/claims.md for the language that must never appear here.
class ComplianceController < ApplicationController
  skip_before_action :authenticate_user!
  # Genuinely public: these must be readable by a visitor of a customer's site
  # who wants to know what is being collected about them, and such a person has
  # no account here and never will.
  skip_after_action :verify_authorized

  # Public documents stay public even before first-run setup.
  always_reachable

  def privacy; end
  def dpa; end

  # Tastatur's own privacy policy, covering the account data we control.
  # Distinct from #privacy, which documents what the product collects from a
  # customer's VISITORS and is the page a customer links from their own policy.
  def privacy_policy; end

  def terms; end
end
