# A credential for the API: an identify key for one site's server, or an agent key
# for an account (see MakeAgentKeysAccountLevel).
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

  # What a key may do. Deliberately two separate capabilities with no "all":
  # the key given to an agent reads, the key given to a server writes, and
  # nothing is granted by omission. A new endpoint names the scope it needs
  # rather than inheriting whatever the key happens to hold.
  SCOPES = {
    "write:identify" => "Attach a customer to a visitor (POST /api/v1/identify)",
    "read:analytics" => "Read traffic, goals, funnels, campaigns and revenue (MCP at /mcp)"
  }.freeze

  # What a key created without saying gets. Matches the column default, and is
  # what every key could do before scopes existed.
  DEFAULT_SCOPES = ["write:identify"].freeze

  # Exactly one of these is set: an identify key belongs to a site, an agent key to
  # an account (see MakeAgentKeysAccountLevel).
  belongs_to :site, optional: true
  belongs_to :account, optional: true
  # The member who made an agent key; see the migration. Nil for identify keys.
  belongs_to :user, optional: true

  has_secure_password :token, validations: false

  validates :name, presence: true
  # Per person: two teammates may each have a key called "claude". An identify key has
  # no owner and is named per site. Mirrored by two partial unique indexes.
  validates :name, uniqueness: { scope: %i[account_id user_id] }, if: :account_id?
  validates :name, uniqueness: { scope: :site_id }, if: :site_id?
  validate :belongs_to_exactly_what_its_scope_needs
  validates :scopes, length: { minimum: 1, message: "must include at least one permission" }
  validates :user, presence: { message: "is required for a key that reads analytics" }, if: :agent?
  validate :scopes_are_known
  validates :token_digest, :token_prefix, :last_four, presence: true

  scope :live, -> { where(revoked_at: nil) }
  # Keys that only read, as opposed to the identify keys an admin keeps for a server.
  scope :agent_keys, -> { where("NOT ('write:identify' = ANY (api_keys.scopes))") }
  scope :ordered, -> { order(revoked_at: :asc, created_at: :desc) }

  attr_reader :plaintext

  # Builds a key and returns it with `#plaintext` set. The caller must save it.
  #
  # The token is `tk_<prefix>_<secret>`: the prefix is an indexed, non-secret
  # lookup handle, the secret is 32 bytes of urlsafe base64. Splitting them is
  # what lets authentication do ONE bcrypt comparison instead of one per key in
  # the table — see the migration for why that distinction is a denial-of-service
  # issue rather than a performance note.
  def self.generate!(name:, site: nil, account: nil, scopes: DEFAULT_SCOPES, user: nil)
    prefix = SecureRandom.alphanumeric(PREFIX_LENGTH).downcase
    secret = SecureRandom.urlsafe_base64(SECRET_LENGTH)
    plaintext = "#{PREFIX}_#{prefix}_#{secret}"

    key = new(site: site, account: account, name: name, user: user, token_prefix: prefix, scopes: Array(scopes).map(&:to_s).uniq,
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

    authenticated = key.authenticate_token(token)
    return nil unless authenticated && authenticated.owner_still_member?

    authenticated
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

  # The form's single-choice view of `scopes`: the key's first permission.
  def scope = scopes.first

  # A key that only reads. These are the ones any member may make, and the ones
  # that are bound to their maker.
  def agent? = scopes.present? && scopes.all? { |scope| scope.start_with?("read:") }

  # Checked on EVERY request, not at creation: the whole point is that removing
  # someone from the organisation takes their keys with them. One indexed lookup,
  # and only for keys that have an owner.
  def owner_still_member?
    return true if user_id.nil?

    Membership.exists?(user_id: user_id, account_id: owning_account_id)
  end

  # The account this key acts within, whichever way it is attached.
  def owning_account_id = account_id || site&.account_id

  def allows?(scope) = scopes.include?(scope.to_s)

  # One short description per scope this key holds, for the list screen.
  def scope_descriptions = scopes.filter_map { |scope| SCOPES[scope] }

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

  private

  # A key that reads lives on the account and a key that writes lives on a site, and
  # mixing them up is the bug the database check also refuses. Said here first so the
  # error reads as a sentence instead of a constraint name.
  def belongs_to_exactly_what_its_scope_needs
    if site_id.present? && account_id.present?
      errors.add(:base, "must belong to a site or an account, not both")
    elsif agent? && account_id.blank?
      errors.add(:account, "is required for a key that reads analytics")
    elsif !agent? && site_id.blank?
      errors.add(:site, "is required for a key that writes")
    end
  end

  def scopes_are_known
    unknown = scopes - SCOPES.keys
    errors.add(:scopes, "contains unknown permissions: #{unknown.join(', ')}") if unknown.any?
  end
end
