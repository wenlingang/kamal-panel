module Collectors
  # Connectivity probe at onboarding: lists success/failure host by host (spec 5.3 step 2).
  class ReachabilityProbe
    def self.call(managed_app)
      session = SshSession.new(managed_app)

      session
        .capture_many(managed_app.app_hosts) { "echo ok" }
        .transform_values { |result| result.error.nil? && result.stdout.to_s.strip == "ok" }
    end
  end
end
