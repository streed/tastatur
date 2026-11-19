# Validates a POST /waitlist body before any of it reaches Waitlist::Join.
#
# The form is public and unauthenticated, so this is a boundary in the §2 sense
# even though the shape is three fields. DECLARED KEYS ARE THE POINT, as in
# IdentifyContract: a bot posting a form dump at this endpoint must not be able
# to set a column nobody intended, and `feature` in particular decides which
# list somebody lands on.
class WaitlistSignupContract < Dry::Validation::Contract
  params do
    required(:email).filled(:string, max_size?: 320)

    # Both are constrained rather than free text: they end up in a database
    # column and on an internal report, and neither is worth trusting to a form
    # field that anyone can rewrite.
    optional(:feature).filled(:string, included_in?: WaitlistSignup::FEATURES)
    optional(:source).maybe(:string, max_size?: 40)
  end

  # Deliberately the same regexp the model uses, so a rejection here and a
  # rejection there cannot disagree — the failure mode being a form that accepts
  # an address the model then refuses to save, which surfaces as a 500 on a
  # marketing page.
  rule(:email) do
    key.failure("does not look like an email address") unless URI::MailTo::EMAIL_REGEXP.match?(value.strip)
  end
end
