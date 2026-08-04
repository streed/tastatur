module EditionHelper
  # A view slot an edition may fill, and which renders nothing when no edition
  # does. See config/application.rb for what an edition is.
  #
  # WHY A SLOT RATHER THAN A GUARDED `render`. The alternative is
  # `render "waitlist_signups/form" if Tastatur.waitlist_enabled?`, and it looks
  # equivalent right up to the point where the predicate and the partial
  # disagree — a feature switched on by one edition whose partial lives in
  # another, or a partial renamed on the private side. Then the community
  # edition raises `ActionView::MissingTemplate` on a page that has nothing to do
  # with the feature, and it raises it in production, on a customer's settings
  # screen. Asking the lookup context whether the template exists makes the
  # absent case the *defined* case: no edition, no markup, no error.
  #
  # It is deliberately not a general "render anything" escape hatch. Everything
  # about which this application makes a decision — whether billing is on,
  # whether there is a marketing site — is a predicate on `Tastatur`, and those
  # predicates are what a template should branch on. This is for the narrower
  # thing a predicate cannot express: markup that simply is not in this
  # repository.
  #
  # `formats: [:html]` because the slots are page furniture and the .md
  # renderings of public pages must not pick up an HTML partial by accident —
  # markdown templates are whitespace-sensitive (§17) and a stray <div> in one
  # is invisible until somebody reads the rendering.
  def edition_partial(partial, **locals)
    return unless lookup_context.exists?(partial, [], true, formats: [ :html ])

    render partial: partial, locals: locals
  end
end
