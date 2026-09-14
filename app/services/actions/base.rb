# 封闭动作集（spec 7.3）。面板永远不执行任意命令。
#
# 新增动作必须在 REGISTRY 中显式登记——没有「按名字动态查找类」这种事，
# 那等价于把动作名当成代码来执行。
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

    # 动作只声明自己会不会改变线上状态；谁能执行由 ManagedAppPolicy#run? 解释。
    # 此前这里是 `def self.required_role = "operator"`——把角色字符串写在动作类
    # 上，等于让授权规则同时活在动作层和控制器层两个地方。
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
      # 面板的临时目录里没有 git 仓库（README：面板永不接触源码），所以
      # `app boot` 与裸 `rollback` 绝不能指望 Kamal 自己从 git 推导版本号——
      # 那会直接报错。这里把"必须显式带版本号"这条调用方义务，从注释
      # 升级成会真正抛异常的代码。
      def require_version!
        return target_version.to_s if target_version.present?

        raise ArgumentError,
          "#{self.class} 必须显式提供 target_version：面板的临时目录没有 git 仓库，" \
          "Kamal 无法自行推导版本号"
      end

      # Kamal 的 `modify(lock: true)`（stop/start/boot 都走这条路）无条件
      # 读一次 config.version 去生成锁的审计文案——即使动作本身根本不关心
      # 版本号（stop/start）。没有 git 仓库时这一步会直接抛异常，跟
      # require_version! 保护的场景是同一个根因，只是这里不需要、也不该
      # 强迫调用方提供一个「真实」版本号：stop/start 认的是远端容器当前
      # 正在跑的版本（current_running_version，另一条不受这个值影响的
      # 路径），这里给的只是一个占位符，让 Kamal 能把锁的文案算出来。
      def version_for_lock
        target_version.presence || "panel-#{SecureRandom.hex(4)}"
      end
  end
end
