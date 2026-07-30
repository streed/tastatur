# frozen_string_literal: true

# Machine readers — LLM agents and AI crawlers, mostly — ask for a page with
# `Accept: text/markdown`. Registering the type lets Rails negotiate it like
# any other format, so the pages that answer (the marketing page and the docs)
# do it with an ordinary `.md.erb` template next to the HTML one. See
# PagesController#home and DocsController#show.
Mime::Type.register "text/markdown", :md, %w[text/x-markdown], %w[markdown]

# ERB escapes `<%= %>` output for every format not on this list, which is right
# for HTML and ruinous for markdown: the docs template interpolates the site key
# and instance URLs into fenced code blocks, and `<script>` arriving as
# `&lt;script&gt;` corrupts the one thing that page exists to convey. Everything
# those templates interpolate is instance configuration, never visitor input.
ActiveSupport.on_load(:action_view) do
  ActionView::Template::Handlers::ERB.escape_ignore_list += ["text/markdown"]
end
