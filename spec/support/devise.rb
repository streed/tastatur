RSpec.configure do |config|
  # `sign_in user` in request specs. Warden's request-spec helpers bypass the
  # sign-in form, which is what you want in a spec about something other than
  # signing in — otherwise every authenticated example carries an unrelated
  # form submission that can fail for its own reasons.
  config.include Devise::Test::IntegrationHelpers, type: :request
  config.include Devise::Test::ControllerHelpers, type: :controller
end
