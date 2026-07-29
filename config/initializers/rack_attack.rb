class Rack::Attack
  throttle("req/ip", limit: 300, period: 5.minutes) { |req| req.ip }

  throttle("logins/ip", limit: 5, period: 20.seconds) do |req|
    req.ip if req.path == "/users/sign_in" && req.post?
  end

  throttle("logins/email", limit: 5, period: 20.seconds) do |req|
    if req.path == "/users/sign_in" && req.post?
      req.params.dig("user", "email")&.downcase&.strip
    end
  end

  throttle("signups/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.path == "/users" && req.post?
  end

  throttle("password_resets/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.path == "/users/password" && req.post?
  end
end

ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_, _, _, _, payload|
  Rails.logger.warn "[Rack::Attack] Throttled #{payload[:request].ip}"
end
