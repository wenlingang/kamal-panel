require "json"
require "shellwords"

module Collectors
  # 每个 ManagedApp × 每台 host 一条命令，取回该应用的全部容器。
  #
  #   docker ps --all --filter label=service=X --filter label=destination=Y --format <见 DOCKER_FORMAT_TEMPLATE>
  #
  # --all 是关键：已停止的旧版本容器一并返回，这就是回滚候选列表，
  # 面板无需自建版本历史（spec 6.1）。kamal rollback VERSION 本身也要求
  # 目标版本的容器在每台主机上仍然存在，所以这里绝不能省掉 --all。
  class ContainerCollector
    # docker ps 通了、但每一行都读不懂时写进 observations.error 的那句话。
    #
    # 它是【持久化字段】的内容，按设计 13 §2.1 的判据不翻译。但 ManagedAppStatus
    # 要靠它把"读不懂"和"失联"分开——所以短语只能有一个出处。此前它在采集器和
    # _host_table.html.erb 里各存一份，谁改了谁那份，另一边会静默退化成"失联"。
    UNPARSEABLE_OUTPUT_MARKER = "输出无法解析".freeze

    def self.unparseable_output_error(line_count)
      "docker ps #{UNPARSEABLE_OUTPUT_MARKER}（#{line_count} 行全部解析失败），详情见日志"
    end

    # 不用 `--format '{{json .}}'`：那样 docker 会把所有 label 压平成一个
    # 逗号拼接的 "k=v,k=v" 字符串（.Labels 字段），而 service/destination
    # 本身没有任何字符集限制（不能靠"禁止逗号"来解决——那是在收紧 Kamal
    # 本来接受的配置，Task 6 已经因为这类"面板比 Kamal 更严格"的问题
    # 吃过教训）。一旦某个值里带逗号，逗号拼接的字符串就没法可靠地反切分：
    # role/version 会被错误解析，而这正是产品要在事故现场展示的数据——
    # 解析错了比崩溃更糟，会误导正在排障的人。
    #
    # 用 docker 自己的 `.Label "name"` 函数按字段单独取值、`{{json ...}}`
    # 单独编码，从源头消灭这处歧义：每个字段各自 JSON 转义，无论值里有
    # 没有逗号、引号，都不影响其他字段。已用真实 fake host（Docker
    # 29.8.0）验证过这个模板语法可用（含 role/destination 里带逗号的
    # 用例，见 container_collector_test.rb）。
    DOCKER_FORMAT_TEMPLATE = '{"name":{{json .Names}},"state":{{json .State}},' \
                             '"status":{{json .Status}},"role":{{json (.Label "role")}},' \
                             '"destination":{{json (.Label "destination")}}}'

    def self.call(managed_app)
      new(managed_app).call
    end

    def initialize(managed_app)
      @managed_app = managed_app
      @observed_at = Time.current
    end

    def call
      rows = []

      results.each do |host, result|
        rows.concat(
          if result.error
            [ unreachable_row(host, result.error) ]
          else
            container_rows(host, result.stdout)
          end
        )
      end

      Observation.insert_all!(rows) if rows.any?
      rows.size
    end

    private
      attr_reader :managed_app, :observed_at

      def results
        SshSession.new(managed_app).capture_many(managed_app.app_hosts) { docker_ps_command }
      end

      # service/destination 来自用户粘贴的 deploy.yml——Kamal::ConfigParser
      # 校验过 destination 的字符集（DESTINATION_FORMAT：字母数字下划线
      # 连字符），但 service 本身没有对应的字符集限制（Kamal 对 service
      # 只做了存在性检查）。这条命令行最终交给 Net::SSH#exec!，本质就是
      # "在远程 shell 里执行这段文本"，所以这里必须转义——不能假设上游
      # 已经把它们收紧到安全字符集。host/port/proxy 已经在 ConfigParser
      # 里校验过，不需要在这里重复转义；role 从不出现在这条命令行里
      # （过滤只按 service/destination），没有对应的注入面。
      def docker_ps_command
        filters = [ "label=service=#{Shellwords.escape(managed_app.service)}" ]

        if managed_app.destination.present?
          filters << "label=destination=#{Shellwords.escape(managed_app.destination)}"
        end

        [
          "docker ps --all",
          *filters.map { |f| "--filter #{f}" },
          "--format #{Shellwords.escape(DOCKER_FORMAT_TEMPLATE)}"
        ].join(" ")
      end

      def container_rows(host, stdout)
        lines = stdout.to_s.lines.map(&:strip).reject(&:blank?)

        # 没有任何容器也要留痕：这台机器是可达的，只是没东西在跑
        return [ empty_row(host) ] if lines.empty?

        rows = lines.filter_map { |line| container_row(host, line) }

        # 每一行都解析失败时绝不能写零行：latest_for 取的是 max(observed_at)，
        # 零行会让上一轮的旧观测继续以"最新"的身份被渲染成当前状态——一次
        # "我没能看"被静默地读成了"上次的正常"（见 final review I1）。
        # 兄弟采集器 ProxyCollector 面对同一种失败（远端回答了、认不出）落一条
        # unrecognized_row；Observation 没有 raw 列存不了原始 payload，
        # 但可以复用它已有的 unreachable_row 语义（reachable: false + error），
        # 让这一行诚实地承认"这台机器这一轮没有可信数据"，而不是假装什么都
        # 没发生。
        return [ unparseable_row(host, lines.size) ] if rows.empty?

        rows
      end

      def container_row(host, line)
        data = JSON.parse(line)
        name = data["name"].to_s
        role = data["role"].presence
        destination = data["destination"].presence

        base_row(host).merge(
          role: role,
          container_name: name,
          version: extract_version(name, role, destination),
          docker_status: data["state"],
          health: extract_health(data["status"])
        )
      rescue JSON::ParserError => e
        # 不记录原始行内容，也不记录 e.message：JSON::ParserError 的
        # message 里本身就会带一段"出错位置附近"的原文摘录（比如
        # "unexpected token 'xxx'"），而这一行的内容来自 label 值，
        # label 值又来自用户粘贴的 deploy.yml——不能假设它不含敏感信息。
        # 只记录足够定位问题的上下文（host/app/异常类名/行长度），不记录
        # 任何从这一行内容衍生出来的文本。
        Rails.logger.error(
          "[Collectors::ContainerCollector] managed_app_id=#{managed_app.id} host=#{host} " \
          "无法解析 docker ps 输出的一行（#{e.class}，长度 #{line.to_s.bytesize} 字节），已跳过该行"
        )
        nil
      end

      # 容器名格式 service-role-destination-VERSION
      # （Kamal::Configuration::Role#container_name）。不能按位置切分——
      # service/role/destination 本身都可能含连字符，只有从已知前缀
      # 做字符串剥离才是可靠的。
      def extract_version(name, role, destination)
        prefix = [ managed_app.service, role, destination ].compact.join("-")
        return nil unless name.start_with?("#{prefix}-")

        name.delete_prefix("#{prefix}-")
      end

      # docker ps 的 Status 形如 "Up 3 minutes (healthy)"
      def extract_health(status)
        status.to_s[/\((healthy|unhealthy|health: starting)\)/, 1]
      end

      def base_row(host)
        { managed_app_id: managed_app.id, host: host, reachable: true,
          observed_at: observed_at, created_at: observed_at }
      end

      def empty_row(host)
        base_row(host)
      end

      def unreachable_row(host, error)
        base_row(host).merge(reachable: false, error: error.truncate(255))
      end

      def unparseable_row(host, line_count)
        base_row(host).merge(reachable: false,
                             error: self.class.unparseable_output_error(line_count))
      end
  end
end
