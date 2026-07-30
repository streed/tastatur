# Routes a model by an unguessable public identifier instead of its primary key.
#
# THE BUG THIS EXISTS TO PREVENT: `resources :sites, param: :public_token`
# renames the route *segment*, but `site_path(site)` still calls `to_param`,
# which defaults to `id`. So every generated link points at /sites/2 while the
# route expects a token, and every link 404s. Renaming the param without
# overriding to_param is a silent, total break.
#
# Including this concern does both halves at once.
module PubliclyIdentified
  extend ActiveSupport::Concern

  class_methods do
    # The column used in URLs. Defaults to :public_id; Site overrides it with
    # :public_token, which is short and human-readable because it is pasted into
    # a script tag.
    def public_identifier(column = :public_id)
      @public_identifier = column

      define_method(:to_param) { public_send(column)&.to_s }
    end

    def public_identifier_column
      @public_identifier ||= :public_id
    end

    # Raises RecordNotFound for an unknown identifier, exactly like `find`, so a
    # bad or revoked identifier is indistinguishable from one that never existed.
    def find_by_public_id!(value)
      find_by!(public_identifier_column => value)
    end
  end
end
