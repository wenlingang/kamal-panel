# The closed action set (spec 7.3). The panel never executes arbitrary commands.
module Actions
  class Base
    class UnknownAction < StandardError; end
    # A target (accessory name / host) that the app's own config doesn't declare. Raised before
    # anything is audited or run: the closed action set only ever aims at things deploy.yml lists.
    class InvalidTarget < StandardError; end
    # A version that can't be an image tag. The value lands in argv as `--version <v>` /
    # `rollback <v>`; one starting with "-" would be read by Thor as an option.
    class InvalidVersion < StandardError; end

    # Docker's own tag grammar: [A-Za-z0-9_][A-Za-z0-9_.-]{0,127}.
    VERSION_FORMAT = /\A\w[\w.-]{0,127}\z/

    def self.registry
      {
        "deploy"            => Actions::Deploy,
        "restart"           => Actions::Restart,
        "stop"              => Actions::Stop,
        "start"             => Actions::Start,
        "maintenance"       => Actions::Maintenance,
        "live"              => Actions::Live,
        "rollback"          => Actions::Rollback,
        "accessory_restart" => Actions::AccessoryRestart,
        "accessory_reboot"  => Actions::AccessoryReboot,
        "proxy_restart"     => Actions::ProxyRestart,
        "prune"             => Actions::Prune,
        "force_unlock"      => Actions::ForceUnlock,
        "logs"              => Actions::Logs
      }
    end

    def self.all = registry.values

    def self.find(name)
      registry.fetch(name.to_s) { raise UnknownAction, "未知动作：#{name.inspect}" }
    end

    def self.action_name = registry.key(self)

    # An action only declares whether it changes live state; who may run it is interpreted by
    # ManagedAppPolicy#run?.
    def self.mutating? = true
    def self.requires_lock? = true
    def self.confirm_by_name? = false

    # Whether the action needs a version from the caller at all (not a lock placeholder).
    def self.requires_version? = false

    # Deploys and rollbacks change which version runs; the panel records each one as a
    # DeployEvent (source "panel") next to the hook-reported and inferred ones.
    def self.records_deploy_event? = false

    # What a target names for this action: nil (takes none), :host or :accessory.
    def self.target_kind = nil
    def self.requires_target? = false

    def initialize(managed_app, target_version: nil, target: nil)
      @managed_app = managed_app
      @target_version = target_version
      @target = target.to_s.presence
    end

    attr_reader :managed_app, :target_version, :target

    def cli_args = raise(NotImplementedError)

    def affected_hosts = managed_app.cached_app_hosts

    # Everything the caller supplied, checked before anything is audited or run.
    def validate!
      validate_version!
      validate_target!
    end

    def validate_version!
      if target_version.blank?
        raise InvalidVersion, "#{self.class.action_name} 需要指定版本" if self.class.requires_version?
        return
      end

      raise InvalidVersion, "#{target_version.inspect} 不是合法的镜像标签" unless target_version.to_s.match?(VERSION_FORMAT)
    end

    # The target must be one the parsed config declares, checked against the config itself rather
    # than any client-side list. Also refuse anything starting with "-": the value lands in argv,
    # and Thor would read it as an option even though no shell is involved.
    def validate_target!
      if target.nil?
        raise InvalidTarget, "#{self.class.action_name} 需要指定目标" if self.class.requires_target?
        return
      end

      raise InvalidTarget, "#{self.class.action_name} 不接受目标" if self.class.target_kind.nil?

      unless !target.start_with?("-") && target_choices.include?(target)
        raise InvalidTarget, "#{target.inspect} 不是该应用配置里声明的 #{self.class.target_kind}"
      end
    end

    def target_choices
      case self.class.target_kind
      when :host      then managed_app.parsed_config.app_hosts
      when :accessory then managed_app.parsed_config.accessory_names
      else []
      end
    end

    private
      def require_version!
        return target_version.to_s if target_version.present?

        raise ArgumentError,
          "#{self.class} 必须显式提供 target_version：面板的临时目录没有 git 仓库，" \
          "Kamal 无法自行推导版本号"
      end

      # Every locked Kamal command reads config.version when it writes the lock (lock.acquire
      # records it), and without --version that falls back to git, which the panel's temp dir
      # doesn't have. So even commands that don't care about the version pass a placeholder.
      def version_for_lock
        target_version.presence || "panel-#{SecureRandom.hex(4)}"
      end

      def validated_target
        validate_target!
        target
      end
  end
end
