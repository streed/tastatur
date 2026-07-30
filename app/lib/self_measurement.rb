# The half of self-measurement a page cannot perform for itself.
#
# Almost everything this instance records about its own use is a click or a form
# submission, annotated in the markup and reported by the analytics Stimulus
# controller. Signing in is the exception: the sign-in form looks identical
# whether the password was right or wrong, and the page that finally renders is a
# redirect target with no idea how the visitor arrived at it. So the server
# records the step and the next page carries it, as the same data attribute the
# controller already understands.
#
# The session rather than the flash, and the two are not interchangeable here. A
# flash entry is discarded by the request that follows the one that set it,
# whether or not that request rendered anything — and a successful sign-in
# redirects twice, to "/", which redirects again to the site list. The flash
# would be swept by that intermediate hop and the event would never fire.
#
# WHAT MAY BE RECORDED: the shape of the step, never who took it. `first_sign_in`
# is a boolean rather than a user id or an email for the reason the whole product
# exists — two events that can be tied back to one person are the thing we tell
# customers we do not collect, and collecting it about ourselves would make that
# claim untrue rather than merely unproven.
module SelfMeasurement
  # String keys throughout: the session is serialised to JSON in the cookie, so a
  # symbol written here comes back as a string on the next request and a lookup
  # by symbol would silently miss.
  SESSION_KEY = "self_measurement_event"

  def self.record(session, name, **props)
    session[SESSION_KEY] = { "name" => name, "props" => props.transform_keys(&:to_s) }
  end

  # Read-and-clear, returning attributes for the <body> tag — an event recorded
  # once has to fire once. Empty when nothing is pending, so the layout can
  # render it unconditionally rather than wrapping the body tag in a conditional.
  def self.take(session)
    event = session.delete(SESSION_KEY)
    return {} if event.blank?

    attributes = { analytics_load_event: event["name"] }
    attributes[:analytics_load_props] = event["props"].to_json if event["props"].present?

    { data: attributes }
  end
end
