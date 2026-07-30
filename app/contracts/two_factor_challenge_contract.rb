# The code typed into the two-factor challenge screen.
#
# A contract for a single field looks like ceremony, and it is not. This is an
# unauthenticated endpoint taking attacker-controlled input, and it is the last
# thing between that input and bcrypt. Rails strong parameters would let
# `code[]=1` through as an Array, and `BCrypt::Password#==` raises on a
# non-String rather than returning false — so a request anyone can craft in a
# URL bar becomes a 500 on the sign-in path.
#
# The normalisation earns its place too. People paste codes out of a mail client
# that adds a trailing space, or read them back as "123 456", and a challenge
# that refuses a code the user can plainly see on screen gets blamed on the
# second factor as a concept rather than on the parser.
class TwoFactorChallengeContract < Dry::Validation::Contract
  # Coercion, not validation, and it runs before the rule below — so the rule
  # judges what will actually be compared rather than what was typed.
  DIGITS = Types::Strict::String.constructor { |value| value.to_s.strip.delete("^0-9") }

  params do
    required(:code).filled(DIGITS)
  end

  # Exactly the issued length, checked here rather than by trying it: a
  # submission that cannot possibly be a code must not consume one of the five
  # attempts budgeted for somebody who mistyped a real one.
  rule(:code) do
    expected = TwoFactor::IssueChallenge::CODE_LENGTH

    key.failure("must be #{expected} digits") unless value.length == expected
  end
end
