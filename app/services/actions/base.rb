# The closed action set (spec 7.3). The panel never executes arbitrary commands.
module Actions
  class Base
    class UnknownAction < StandardError; end

    def self.registry
      {
        "restart"      => Actions::Restart,
        "stop"         => Actions::Stop,
        "start"        => Actions::Start,
        "rollback"     => Actions::Rollback,
        "force_unlock" => Actions::ForceUnlock,
        "logs"         => Actions::Logs
      }
    end

    def self.all = registry.values

    def self.find(name)
      registry.fetch(name.to_s) { raise UnknownAction, "未知动作：#{name.inspect}" }
    end

    # An action only declares whether it changes live state; who may run it is interpreted by
    # ManagedAppPolicy#run?.
    def self.mutating? = true
    def self.requires_lock? = true
    def self.confirm_by_name? = false

    def initialize(managed_app, target_version: nil)
      @managed_app = managed_app
      @target_version = target_version
    end

    attr_reader :managed_app, :target_version

    def cli_args = raise(NotImplementedError)

    def affected_hosts = managed_app.cached_app_hosts

    private
      def require_version!
        return target_version.to_s if target_version.present?

        raise ArgumentError,
          "#{self.class} 必须显式提供 target_version：面板的临时目录没有 git 仓库，" \
          "Kamal 无法自行推导版本号"
      end

      def version_for_lock
        target_version.presence || "panel-#{SecureRandom.hex(4)}"
      end
  end
end
