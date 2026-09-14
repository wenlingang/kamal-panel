require "json"

module Collectors
  # 取回每台机器上 kamal-proxy 的路由表。
  #
  #   docker exec kamal-proxy kamal-proxy list --json
  #
  # 这是唯一能回答「流量实际到达哪个容器」的数据源——docker ps 看不出
  # 一个正在运行的容器是否在接流量（spec 6.1）。
  #
  # 每台主机每轮采集恰好落一行到三种状态之一（reachable / service_name /
  # raw 三列的组合即状态标记，Task 10 据此渲染）：
  #
  #   1. 找到路由：      reachable=true,  service_name 有值,  raw=该条目原文
  #   2. 可达但无代理数据：reachable=true,  service_name=nil,  raw=nil
  #      （机器上没跑 kamal-proxy，或 kamal-proxy 上没有属于本应用的路由——
  #      这是完全正常的情况，用户可能用别的入口，因此不视为错误）
  #   3. 主机不可达：     reachable=false, error=SSH/连通性错误信息
  #
  # 另有一种边界状态嵌在状态 2 的形状里：reachable=true 但 raw 有值、
  # service_name=nil——表示 kamal-proxy 返回了合法 JSON，但形状认不出来
  # （版本升级换了字段名等）。Task 10 应把它显示为「拿到了数据但解析不了」，
  # 而不是「没有路由数据」。
  #
  # kamal-proxy list --json 的实际输出（v0.10.0 实测）是一个以 service
  # 名为 key 的对象：
  #
  #   {"blog-web-production":{"targets":["blog-web-production-aaa:80"],
  #     "state":"running", ...}}
  #
  # 而不是 list.go 源码看起来暗示的「Targets 数组」。由于该形状未必
  # 跨版本保持稳定，这里对形状保持宽容：能识别的字段尽量取出，认不出时
  # 把原始 JSON 存进 raw 列，而不是丢弃这台主机的数据。
  class ProxyCollector
    # 不吞掉 stderr：`2>/dev/null` 曾经让"kamal-proxy 容器根本不存在/挂了"
    # 与"kamal-proxy 正常但没有任何路由"在库里变成完全相同的一行（都是
    # 空 stdout → empty_row）。Net::SSH::Connection::Session#exec! 默认把
    # on_data 与 on_extended_data 合并进同一个字符串返回（见 net-ssh 源码
    # session.rb#exec!/#exec），所以去掉这个重定向后，docker 的
    # "Error: No such container: kamal-proxy" 会和 kamal-proxy list 的
    # 输出落到同一个 stdout 里——对空路由表（合法 JSON）没有影响，但对
    # "根本没跑 kamal-proxy" 这种情况，stdout 不再是空字符串，而是这段
    # 认不出的错误文本，会走 unrecognized_row 分支存进 raw 列，从而与
    # "跑着但是空路由表"区分开（见 final review 分诊 2 / M2 的姊妹项）。
    COMMAND = "docker exec kamal-proxy kamal-proxy list --json".freeze

    def self.call(managed_app)
      new(managed_app).call
    end

    def initialize(managed_app)
      @managed_app = managed_app
      @observed_at = Time.current
    end

    def call
      rows = results.flat_map { |host, result| rows_for(host, result) }

      ProxyTarget.insert_all!(rows) if rows.any?
      rows.size
    end

    private
      attr_reader :managed_app, :observed_at

      def results
        SshSession.new(managed_app).capture_many(managed_app.app_hosts) { COMMAND }
      end

      def rows_for(host, result)
        return [ unreachable_row(host, result.error) ] if result.error
        return [ empty_row(host) ] if result.stdout.blank?

        parsed = safe_parse(json_payload(result.stdout))

        # 解析失败，或解析成功但顶层形状既不是 Hash 也不是 Array——
        # 认不出来的合法 JSON 和无法解析的 JSON 一样，都不能当成
        # 「没有路由数据」悄悄吞掉，宁可原样存一行。
        return [ unrecognized_row(host, result.stdout) ] unless recognized_shape?(parsed)

        entries = entries_for(parsed).select { |entry| belongs_to_this_app?(entry) }

        return [ empty_row(host) ] if entries.empty?

        entries.map { |entry| row(host, entry) }
      end

      # kamal-proxy 在 happy path 上偶尔会往 stderr 写一行（已合并进 stdout）。
      # 只取第一个 '{' 或 '[' 起的部分，避免一行噪音把整份路由载荷降级为
      # unrecognized。
      def json_payload(stdout)
        text = stdout.to_s
        start = text.index("{") || text.index("[")
        start ? text[start..] : text
      end

      def safe_parse(stdout)
        JSON.parse(stdout)
      rescue JSON::ParserError
        nil
      end

      # 顶层形状必须是 Hash 或 Array 才认为「认识」；解析失败（也返回 nil）、
      # 或解析出标量/nil（比如意外收到 `null`、一个数字或一个裸字符串）都算
      # 认不出来，交给调用方存原始 payload——两种情况处理方式相同，不需要
      # 区分「解析失败」与「解析出一个我们不认识的合法值」。
      def recognized_shape?(parsed)
        parsed.is_a?(Hash) || parsed.is_a?(Array)
      end

      # 支持两种已知形状：
      #   Hash  {"service-name" => {...}}   —— 实测的 v0.10.0 形状
      #   Array [{"service" => "..."，...}] —— list.go 源码暗示但未观测到的形状
      def entries_for(parsed)
        case parsed
        when Hash  then parsed.map { |name, value| { name: name, value: value } }
        when Array then parsed.map { |value| { name: nil, value: value } }
        end
      end

      def belongs_to_this_app?(entry)
        name = service_name_of(entry).to_s
        return false if name.blank?

        container_prefixes.include?(name)
      end

      def container_prefixes
        managed_app.parsed_config.roles.map { |role| role[:container_prefix] }
      end

      def service_name_of(entry)
        return entry[:name] if entry[:name].present?

        value = entry[:value]
        return nil unless value.is_a?(Hash)

        value["service"] || value["Service"] || value["name"] || value["Name"]
      end

      def target_of(entry)
        value = entry[:value]
        return nil unless value.is_a?(Hash)

        value["targets"] || value["Targets"] || value["target"] || value["Target"] ||
          value["hosts"] || value["Hosts"]
      end

      def state_of(entry)
        value = entry[:value]
        return nil unless value.is_a?(Hash)

        value["state"] || value["State"]
      end

      def row(host, entry)
        base_row(host).merge(
          service_name: service_name_of(entry),
          target: Array(target_of(entry)).join(", ").presence,
          state: state_of(entry),
          raw: raw_json(entry)
        )
      end

      def raw_json(entry)
        entry[:name] ? JSON.generate({ entry[:name] => entry[:value] }) : JSON.generate(entry[:value])
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

      def unrecognized_row(host, stdout)
        base_row(host).merge(raw: stdout.to_s.truncate(10_000))
      end
  end
end
