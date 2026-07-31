# One form pattern, enforced by the builder rather than by remembering.
#
# Every field in the application is a micro-label, a control, and an optional
# hint, in that order, with the same spacing. Writing that markup by hand in
# each template is how a codebase ends up with four slightly different forms —
# so it is written once here and every form calls `f.field`.
#
# Installed as the default builder in ApplicationController, which means it
# applies to Devise's forms too.
class TastaturFormBuilder < ActionView::Helpers::FormBuilder
  # f.field :domain, "Domain", hint: "Just the hostname."
  # f.field :password, "Password", as: :password_field, autocomplete: "new-password"
  # f.field :timezone, "Timezone", as: :select, choices: [...]
  def field(name, label_text = nil, hint: nil, as: :text_field, choices: nil, wrapper: nil, **options)
    label_text ||= name.to_s.humanize

    control =
      case as
      when :select
        select(name, choices || [], { include_blank: options.delete(:include_blank) },
               **default_options(name, options))
      when :collection_select
        select(name, choices || [], {}, **default_options(name, options))
      when :text_area
        text_area(name, **default_options(name, options))
      when :combobox
        combobox(name, options)
      when :check_box
        return check_box_field(name, label_text, hint: hint, **options)
      else
        public_send(as, name, **default_options(name, options))
      end

    @template.tag.div(class: wrapper) do
      @template.safe_join(
        [
          label(name, label_text, class: "label block mb-2"),
          control,
          field_errors(name),
          hint.present? ? @template.tag.p(hint, class: "text-[12px] text-muted mt-2") : nil
        ].compact
      )
    end
  end

  # A text field that can also be picked from, for the one kind of field in this
  # application where the right answer is a string the customer's own website
  # already produced: a goal's path, a funnel step's event name.
  #
  # `f.field :match_value, "Path or event name", as: :combobox`
  #
  # STILL A TEXT FIELD, and that is not a compromise. A goal is routinely created
  # for a page that has not shipped yet, and `prefix` and `wildcard` matchers are
  # patterns rather than paths — `/blog/**` will never appear in any list of
  # things that happened. A <select> would refuse all three. So the list assists
  # and never constrains, which also means the field degrades to exactly what it
  # was before if the JavaScript never runs.
  #
  # The listbox is rendered empty. Its options are filled in client-side from one
  # JSON payload shared by every picker on the page — see OffersKnownValues for
  # why they are not rendered per field — by value_picker_controller.js, which
  # must be on an ancestor element along with the `kind` control that decides
  # which half of the payload applies.
  def combobox(name, options)
    list_id = "#{field_id(name)}_listbox"

    control = text_field(name, **default_options(name, options.merge(
      # A browser's own saved-value dropdown would cover this one, and it offers
      # what was typed into a field of the same name on any form, which here is
      # another site's paths.
      autocomplete: "off",
      spellcheck: "false",
      role: "combobox",
      aria: { expanded: false, controls: list_id, autocomplete: "list" },
      data: {
        value_picker_target: "input",
        action: "input->value-picker#filter focus->value-picker#open keydown->value-picker#navigate"
      }
    )))

    @template.tag.div(class: "combobox") do
      @template.safe_join(
        [
          control,
          # Rendered hidden and revealed by the controller on connect, so it is
          # never a button that does nothing.
          @template.tag.button("▾", type: "button", class: "combobox-toggle", tabindex: -1, hidden: true,
                                    aria: { label: "Show suggestions" },
                                    data: { value_picker_target: "toggle",
                                            action: "mousedown->value-picker#toggle" }),
          @template.tag.ul(nil, id: list_id, class: "combobox-list", role: "listbox", hidden: true,
                                data: { value_picker_target: "list" })
        ]
      )
    end
  end

  # Inline checkbox: the label sits beside the control rather than above it,
  # because a checkbox above its own label reads as a different question.
  def check_box_field(name, label_text, hint: nil, **options)
    @template.tag.label(class: "flex items-start gap-3 cursor-pointer") do
      @template.safe_join(
        [
          check_box(name, options.merge(class: "mt-1")),
          @template.tag.span do
            @template.safe_join(
              [
                @template.tag.span(label_text, class: "font-medium text-sm"),
                hint.present? ? @template.tag.span(hint, class: "block text-[12px] text-muted mt-0.5") : nil
              ].compact
            )
          end
        ]
      )
    end
  end

  # Error summary at the top of the form. Placed once, above everything, so a
  # failed submission always explains itself in the same place.
  def error_summary
    return unless object.respond_to?(:errors) && object.errors.any?

    @template.tag.div(class: "notice border-signal text-ink", role: "alert") do
      @template.safe_join(
        [
          @template.tag.p("This could not be saved:", class: "font-semibold mb-1"),
          @template.tag.ul(class: "list-disc pl-5 space-y-0.5") do
            @template.safe_join(
              object.errors.full_messages.map { |message| @template.tag.li(message) }
            )
          end
        ]
      )
    end
  end

  # Primary action plus an optional cancel link and an optional destructive
  # action, always in the same order and alignment.
  #
  # `destroy_to:` is a URL, NOT a rendered button, and that is the whole point.
  # The obvious way to write this call site — passing a `button_to` in — was how
  # this worked, and it silently broke every delete button in the application.
  # `button_to` renders a <form>, so the result was a <form> inside the <form>
  # this row belongs to. Nested forms are invalid HTML: the parser DISCARDS the
  # inner start tag, which leaves the delete button owned by the surrounding
  # edit form and its `data-turbo-confirm` attached to an element that no longer
  # exists. Clicking "Delete" then submitted the edit form — measured on the
  # wire, Turbo sent `_method=patch` — so Rails ran `update`, the record was
  # SAVED rather than destroyed, and the redirect landed back on the record
  # looking like nothing had happened. Nothing raises, nothing logs, and the
  # request spec passes because it issues a clean DELETE that no browser ever
  # sends. `spec/requests/destructive_buttons_spec.rb` parses the rendered HTML
  # for nesting so it cannot come back.
  #
  # So the delete form is emitted OUT OF BAND — into `content_for(:detached_forms)`,
  # which the layout yields just before </body>, outside every other form — and
  # the button that lives in this row is associated with it by the HTML `form`
  # attribute. That keeps one visible arrangement, keeps the POST semantics
  # button_to exists for (it still works with JavaScript off), and leaves the
  # caller one line with no id to keep in sync.
  #
  # THE ONE PLACE `destroy_to:` MUST NOT BE USED is a form rendered into a
  # turbo-frame — the widget configuration panel, say. Turbo extracts the
  # matching <turbo-frame> from the response and throws the rest away, and the
  # detached form is by construction outside it, so the button would survive
  # and the form it names would not. Put the destructive action on the page
  # around the frame instead.
  def actions(submit_label, cancel_to: nil, cancel_label: "Cancel",
              destroy_to: nil, destroy_label: "Delete", destroy_confirm: nil)
    @template.tag.div(class: "flex flex-wrap items-center justify-between gap-3 pt-2") do
      @template.safe_join(
        [
          @template.tag.div(class: "flex items-center gap-3") do
            @template.safe_join(
              [
                submit(submit_label, class: "btn btn-primary"),
                cancel_to ? @template.link_to(cancel_label, cancel_to, class: "btn btn-quiet") : nil
              ].compact
            )
          end,
          destroy_to ? destroy_button(destroy_to, destroy_label, destroy_confirm) : nil
        ].compact
      )
    end
  end

  private

  # The visible half of the destructive action, plus the detached form it
  # submits. Both halves derive their id from the same object, so there is no
  # string for a caller to mistype into a button that does nothing.
  def destroy_button(url, label, confirm)
    form_id = destroy_form_id

    @template.content_for(:detached_forms) do
      @template.form_with(url: url, method: :delete, id: form_id, class: "hidden",
                          data: { turbo_confirm: confirm }.compact) { "" }
    end

    @template.tag.button(label, type: "submit", form: form_id,
                                class: "btn btn-quiet text-negative")
  end

  # `dom_id` would put the primary key in the markup, which §10 keeps out of
  # anything public-facing. The routed identifier is what `to_param` already
  # returns.
  def destroy_form_id
    "delete-#{object.model_name.param_key}-#{object.to_param}"
  end

  def default_options(name, options)
    classes = ["field", options.delete(:class)].compact.join(" ")
    classes = "#{classes} border-signal" if object.respond_to?(:errors) && object.errors[name].any?
    options.merge(class: classes)
  end

  # Per-field message in addition to the summary: on a long form the summary is
  # off-screen by the time you reach the offending field.
  def field_errors(name)
    return unless object.respond_to?(:errors)

    messages = object.errors[name]
    return if messages.empty?

    @template.tag.p(messages.first.to_s.upcase_first, class: "text-[12px] text-negative mt-1.5")
  end
end
