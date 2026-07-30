# A delivery method that writes the message to the log instead of sending it.
#
# WHY THIS EXISTS. A self-hosted instance frequently has no mail provider, and
# with `RESEND_API_KEY` unset the consequence was not "email does not work", it was
# "nobody can create an account, ever". Measured on a production-mode boot with the
# key blank:
#
#   User#save! raised Resend::Error::InvalidRequestError: API key is invalid
#   ...but the account persisted anyway, unconfirmed and unable to sign in,
#   ...and its email address was now taken, so it could not be registered again.
#
# The account survives because Devise sends the confirmation from an `after_commit`
# callback, so the record is already written when delivery blows up. The person
# gets a 500, an unusable account, and an address they can never reuse. There is no
# way out of that through the interface.
#
# So when mail is not configured, delivery degrades to the log rather than raising.
# Registration completes, the account is real, and the operator can retrieve the
# confirmation link with `docker compose logs web`.
#
# A NOTE ON WHAT THIS LOGS. Confirmation and password-reset links contain
# single-use tokens, and this writes them to the log. That is a deliberate trade
# and it only happens when the operator has already declined to configure mail:
# the alternative is an instance nobody can sign in to. The boot warning says so.
# Configure RESEND_API_KEY and none of this runs.
module MailDelivery
  class Logged
    # ActionMailer instantiates a delivery method with its settings hash.
    def initialize(settings = {})
      @settings = settings
    end

    attr_reader :settings

    def deliver!(mail)
      Rails.logger.warn(<<~LOG)
        [tastatur] MAIL NOT SENT — no mail provider is configured.
          to:      #{Array(mail.to).join(', ')}
          from:    #{Array(mail.from).join(', ')}
          subject: #{mail.subject}
        #{indented_links(mail)}
          The message body follows. Set RESEND_API_KEY to send this properly.
        #{indented_body(mail)}
      LOG

      mail
    end

    private

    # Pulled out separately because a link is the only part anyone actually needs,
    # and hunting for it in a wrapped HTML body is miserable.
    def indented_links(mail)
      # Stops at a quote, angle bracket or paren so an href yields the URL and not
      # the rest of the tag. Scanning for \S+ produced the same link three times
      # with `"` and `</a` stuck to the end.
      links = body_text(mail)
              .scan(%r{https?://[^\s"'<>)]+})
              .map { |url| url.sub(/[.,;:]+\z/, "") }
              .uniq

      return "  (no links in this message)" if links.empty?

      ["  links:", *links.map { |url| "    #{url}" }].join("\n")
    end

    def indented_body(mail)
      body_text(mail).each_line.map { |line| "    #{line}" }.join.chomp
    end

    # Prefers the plain-text part of a multipart message; falls back to whatever
    # single body there is.
    def body_text(mail)
      part = mail.multipart? ? (mail.text_part || mail.html_part) : mail
      part&.body&.decoded.to_s
    rescue StandardError
      ""
    end
  end
end
