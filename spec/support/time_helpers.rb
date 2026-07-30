# `travel_to` and `freeze_time` in every spec, not just the ones rspec-rails
# happens to type as models or requests.
#
# This suite deliberately does not call `infer_spec_type_from_file_location!`
# (see spec/rails_helper.rb), so a file under spec/services is a plain example
# group and picks up none of the Rails testing mix-ins by location. Anything that
# needs to be available everywhere has to be included here explicitly — which is
# the same reason spec/support/devise.rb and spec/support/active_job.rb exist.
#
# Expiry windows are the reason. Two-factor codes, trusted devices and resend
# intervals are all "is this still valid?" questions, and the only honest way to
# test the far side of a boundary is to stand on it.
RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers
end
