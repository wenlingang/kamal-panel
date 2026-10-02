module Collectors
  # 接入时的连通性探测：逐台列出成功/失败（spec 5.3 第 2 步）。
  class ReachabilityProbe
    def self.call(managed_app)
      session = SshSession.new(managed_app)

      session
        .capture_many(managed_app.app_hosts) { "echo ok" }
        .transform_values { |result| result.error.nil? && result.stdout.to_s.strip == "ok" }
    end
  end
end
