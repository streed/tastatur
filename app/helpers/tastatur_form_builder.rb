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
  def actions(submit_label, cancel_to: nil, cancel_label: "Cancel", destructive: nil)
    @template.tag.div(class: "flex items-center justify-between gap-3 pt-2") do
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
          destructive
        ].compact
      )
    end
  end

  private

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
