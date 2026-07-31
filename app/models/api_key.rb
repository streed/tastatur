# A server-side credential for one site.
#
# THE PLAINTEXT EXISTS EXACTLY ONCE, in memory, on the request that created it.
# `#plaintext` is populated by `generate!` and by nothing else; it is never
# written, never reconstructible, and nil on every row loaded from the database.
# That is why the create action renders the key inline with a "copy it now"
# warning rather than offering it again later — an analytics tool that can show
# you your own API key on demand is one whose database read is equivalent to
# holding the key.
class ApiKey < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  # `tk_` so a key found in a log, a paste, or a public repository is
  # identifiable at a glance as ours and can be reported. GitHub's secret
  # scanning works on exactly this kind of fixed prefix.
  PREFIX = "tk"
  PREFIX_LENGTH = 8
  SECRET_LENGTH = 32

  # How stale `last_used_at` is allowed to get. See #note_use.
  USE_WRITE_INTERVAL = 1.minute

  belongs_to :site

  has_secure_password :token, validations: false

  validates :name, presence: true, uniqueness: { scope: :site_id }
  validates :token_digest, :token_prefix, :last_four, presence: true

  scope :live, -> { where(revoked_at: nil) }
  scope :ordered, -> { order(revoked_at: :asc, created_at: :desc) }

  attr_reader :plaintext

  # Builds a key and returns it with `#plaintext` set. The caller must save it.
  #
  # The token is `tk_<prefix>_<secret>`: the prefix is an indexed, non-secret
  # lookup handle, the secret is 32 bytes of urlsafe base64. Splitting them is
  # what lets authentication do ONE bcrypt comparison instead of one per key in
  # the table — see the migration for why that distinction is a denial-of-service
  # issue rather than a performance note.
  def self.generate!(site:, name:)
    prefix = SecureRandom.alphanumeric(PREFIX_LENGTH).downcase
    secret = SecureRandom.urlsafe_base64(SECRET_LENGTH)
    plaintext = "#{PREFIX}_#{prefix}_#{secret}"

    key = new(site: site, name: name, token_prefix: prefix,
              last_four: plaintext.last(4), token: plaintext)
    key.instance_variable_set(:@plaintext, plaintext)
    key
  end

  # Resolves a presented token to a live key, or nil.
  #
  # RETURNS nil FOR EVERY FAILURE, indistinguishably: malformed, unknown prefix,
  # wrong secret, revoked. A caller that could tell "no such key" from "wrong
  # secret" could enumerate valid prefixes, which is the same argument §12 makes
  # for the ingest endpoint always answering 202.
  #
  # The bcrypt comparison runs even when no row was found, against a throwaway
  # digest, so the response time does not reveal whether the prefix existed.
  def self.authenticate(token)
    prefix = extract_prefix(token)
    key = prefix && live.find_by(token_prefix: prefix)

    unless key
      # Constant-ish work for the miss. Without it, an unknown prefix returns in
      # microseconds and a known one takes bcrypt's deliberate ~50ms, which is a
      # timing oracle for "is this prefix real?" that anyone can measure over the
      # internet.
      BCrypt::Password.create("miss", cost: BCrypt::Engine.cost)
      return nil
    end

    key.authenticate_token(token) || nil
  end

  # `split("_", 3)`, and the limit is not cosmetic.
  #
  # The secret is `SecureRandom.urlsafe_base64`, whose alphabet INCLUDES the
  # underscore — so an unlimited split returns four or more parts for roughly
  # half of all generated keys, a `length == 3` check rejects them, and
  # authentication fails for some keys and succeeds for others at random. That is
  # about the worst shape a bug can have: it looks like a flaky network, it
  # cannot be reproduced with the key the reporter has in front of them, and
  # re-issuing the key fixes it half the time.
  #
  # Limiting to three keeps everything after the second underscore as the secret,
  # which is what it always was.
  def self.extract_prefix(token)
    parts = token.to_s.split("_", 3)
    return nil unless parts.length == 3 && parts.first == PREFIX && parts.last.present?

    parts[1].presence
  end
  private_class_method :extract_prefix

  def revoked? = revoked_at.present?
  def live? = !revoked?

  def revoke!
    update!(revoked_at: Time.current)
  end

  def masked = "#{PREFIX}_#{token_prefix}_#{'•' * 8}#{last_four}"

  # THROTTLED TO ONE WRITE A MINUTE, and the throttle is the reason this method
  # exists rather than an `update_column` at the call site.
  #
  # This runs on every authenticated API request. A customer's server posting an
  # identify call per signup is nothing; one posting server-side pageviews is
  # thousands per minute, and an unthrottled write turns a read-only
  # authentication check into a row update per request — on a row every one of
  # those requests also has to read, so they serialise behind each other's locks.
  #
  # A minute of staleness is invisible in the only place this is displayed ("last
  # used 3 minutes ago") and removes the contention entirely. `update_column`
  # skips validations and callbacks deliberately: nothing about this write should
  # be able to fail the request it is attached to.
  def note_use(at: Time.current)
    return if last_used_at.present? && last_used_at > at - USE_WRITE_INTERVAL

    update_column(:last_used_at, at)
  end
end
