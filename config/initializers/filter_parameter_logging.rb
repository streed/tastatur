# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
#
# THE LAST THREE ARE NOT GENERIC, and each names something this application in
# particular treats as a credential:
#
#   :code       the emailed six-digit second factor. It is short-lived and
#               attempt-budgeted, but it is the whole of the second factor for
#               the ten minutes it lives, and an exception report is the one
#               place params are still written out in full.
#   :slug       a SharedLink slug. For a public shared dashboard the slug IS the
#               secret — see the class comment on SharedDashboardsController —
#               so logging one is logging the dashboard.
#   :signature  a webhook signature header echoed into params by anything that
#               copies the raw request.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :code, :slug, :signature
]
