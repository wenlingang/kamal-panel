require "open3"
require "json"
require "tmpdir"
require "pathname"
require "net/ssh/proxy/jump"
require "resolv"

# 在受限子进程中解析 deploy.yml。
#
# 为什么不直接在进程内调 Kamal::Configuration.create_from：
# Kamal 会对 deploy.yml 做 ERB.new(...).result 再 YAML.unsafe_load，
# 两者都是任意代码执行。用户粘贴的 deploy.yml 是不可信输入。见 spec 7.6。
#
# 临时文件的写入与清理都在本（父）进程完成，而不是在子进程里：子进程
# 解析超时会被 SIGKILL，SIGKILL 跳过 ensure，如果子进程自己创建临时
# 文件，被杀时这些文件（含用户粘贴的完整 payload）就会永久留在磁盘上。
# 父进程不会被杀，Dir.mktmpdir 的块形式自带 ensure 清理，所以无论解析
# 成功、失败还是超时，临时目录都会被删除。子进程只读父进程给它的路径，
# 自己不创建、不删除任何文件。
class Kamal::ConfigParser
  class ParseError < StandardError; end

  DEFAULT_TIMEOUT = 5.seconds
  SCRIPT = Rails.root.join("bin/parse_deploy_config").to_s
  TMPDIR_PREFIX = "kamal-panel-parse"

  # destination 最终会被当成文件名的一部分去拼 "deploy.<destination>.yml"
  # 这条路径——不只是本类自己拼，Kamal 内部定位那份伴随文件时做的是同一件
  # 事。如果放行 "/" 或 ".."，destination 就变成了一个路径穿越面：
  #   - 父进程这边：destination_path(dir).write(...) 可以被指向临时目录
  #     之外的任意位置，内容是攻击者提供的 destination_config_yaml——
  #     任意文件写入。
  #   - 子进程那边：Kamal 用同样的拼接方式去找伴随文件，如果 destination
  #     指向主机上任意一份已存在的 .yml，会被读取、ERB 求值——文件泄露
  #     加代码执行。
  # 这个校验在 ManagedApp 那一层已经做过一次（给用户看得懂的中文报错），
  # 这里再做一遍不是重复劳动，是"这个类是公开 API，不能假设调用方一定会
  # 先校验"——纵深防御的意义就在于任何一层单独失效，另一层还在。
  # ManagedApp 引用的是这个常量，不是另一份拷贝——两处校验、一份定义。
  #
  # 故意不允许点号："us.east" 这种写法会被拒绝，即使 Kamal 自己的
  # destination 习惯上也不用点号（真实项目里见到的都是 production、
  # staging、eu-west 这种形状）。这不是遗漏——destination 最终会成为文件名
  # 的一个片段，点号在文件名里有特殊含义（扩展名分隔符，也是 sub_ext
  # 本来就用来定位"给它换成 .<destination>.yml"这个操作的锚点）。放开
  # 点号在这里等于放开一个本来就该拒绝的语法元素，所以就算以后有人觉得
  # "destination 里带个点很正常"，也不要在没重新想清楚这一条的情况下改这个
  # 正则。
  # 不允许前导连字符，理由与下面 HOST_FORMAT 一致：destination 最终会被
  # 当成 `kamal ... --destination <值>` 的 argv token 拼进 kamal 子进程的
  # 命令行；一个以 "-" 开头的 destination 会被 Thor 的选项解析器当成另一个
  # 开关而不是这个开关的值。目前 Thor 会把它当成格式错误直接拒绝，不是
  # 可利用的注入，但和 HOST_FORMAT 同一份参数注入顾虑没有理由只挡一半。
  DESTINATION_FORMAT = /\A(?!-)[a-zA-Z0-9_-]{1,63}\z/

  # service（deploy.yml 里的顶层 `service:` 字段）最终也会被当成路径/命令
  # 片段拼进去——KamalLock 的锁目录名是
  # "lock-#{service}-#{destination}"，Kamal 自己在远程主机上的
  # apps_directory 也是用 service_and_destination 拼目录名。destination
  # 在这个类里已经因为同样的理由收紧过字符集（见上面 DESTINATION_FORMAT
  # 的注释），service 只是一直没有补上同一条校验——它和 destination 一样
  # 来自不可信的 deploy.yml 内容，一个 service: "../../etc" 或
  # service: "a/b" 会让下游任何"用 service 拼路径"的代码把操作对象挪到
  # 意料之外的地方。这里直接复用 DESTINATION_FORMAT：两个字段最终落地的
  # 都是"目录名的一个片段"，字符集和长度限制没有理由不同。
  SERVICE_FORMAT = DESTINATION_FORMAT

  # 主机名/IPv4 的字符集：字母数字、点、下划线、连字符，不允许以连字符
  # 开头。
  #
  # round 5 之前这里不允许下划线，比 Kamal/SSHKit 本身更严格——真实部署
  # 里 "bastion_1" 这种带下划线的主机名并不罕见（不是标准 DNS 语法，但
  # SSHKit 的主机解析器接受，Kamal 也不会拒绝），面板拒绝它不是"更安全"，
  # 是把一份对 Kamal 而言完全合法的 deploy.yml 判成"配置错误"——这本身
  # 是一种产品失败，不比命令注入更好接受。所以这里恢复下划线。
  #
  # "不允许以连字符开头"是安全考量，不是跟 Kamal/SSHKit 对齐：ssh 客户端
  # 会把以 "-" 开头的参数当成选项而不是主机名——`-oProxyCommand=...`
  # 这类是已知的"参数注入"手法。Kamal/SSHKit 不需要关心这条（它们不会把
  # 这段值交给一个会解析选项的命令行），但本类的两个使用场景
  # （Net::SSH::Proxy::Jump 生成的命令行、以及后续任务会把 servers 主机名
  # 拼进各种命令）都会，所以这里主动收紧——这不是"比 Kamal 更严格地拒绝
  # 合法输入"，是拒绝一个 Kamal/SSHKit 本来也不会遇到、只有面板自己的
  # 命令行拼接场景才会踩到的攻击面。
  HOST_FORMAT = /\A(?!-)[A-Za-z0-9_.-]{1,255}\z/

  # IPv6 字面量的字符集校验交给 Resolv::IPv6::Regex（标准库），不手搓
  # 正则——IPv6 的省略/压缩规则（"::"）、嵌入 IPv4 的形式（如
  # "::ffff:192.0.2.1"）手写正则很容易漏掉边界情况或者过度宽松。
  #
  # 但 Resolv::IPv6::Regex 比我们需要的更宽松：它认识 RFC 4007 的
  # zone id（"fe80::1%eth0" 这种链路本地地址后面跟 "%接口名"），这里
  # 必须显式拒绝任何带 "%" 的地址——不是疏漏，是"%" 正好是
  # Net::SSH::Proxy::Jump 生成命令行模板里 "%h"/"%p" 自己的替换符号，
  # 如果放一个含 "%" 的地址进去，落地之后这段文本会和模板自己的替换
  # 语法混在一起，行为完全取决于 net-ssh 内部怎么处理"替换结果里又出现
  # 了看起来像替换符的文本"——没有把握说这一定安全，收益（支持 zone id）
  # 又几乎为零（面板连接的是用户的部署主机，不是需要靠链路本地地址+
  # zone id 才能到达的同网段设备），所以直接堵死，不要在没有充分理由的
  # 情况下把这条放开。
  IPV6_ZONE_ID = "%"

  # 方括号包住的 IPv6 字面量，可选带 ":port"——"[::1]"、"[::1]:2222"。
  # 只用来识别这个形状、给出"暂不支持"的诚实报错，不代表这个形状会被
  # 接受（见 valid_host? 上方注释）：本类之下没有任何代码会把方括号
  # 剥掉、把端口拆出来——SshSession#connect 把裸字面量原样交给
  # Net::SSH.start → Socket.tcp，两者都不认得这种写法，校验通过之后
  # 连接反而会诡异地失败，所以这里选择在解析阶段就诚实地拒绝。
  BRACKETED_IPV6_FORMAT = /\A\[(?<addr>[^\]]*)\](?::(?<port>[0-9]{1,5}))?\z/

  # 识别"host 后面还跟着 user@ 前缀或 :port 后缀"这个整体形状，专门用来
  # 区分两种拒绝原因：
  #   - 字符集里有 shell 元字符、控制字符之类——这是真的不合法，报"格式
  #     不合法"；
  #   - 只是用了 user@host / host:port / user@host:port 这几种 SSHKit
  #     认识、但面板暂不支持的写法——报"暂不支持"，不要跟上面那种混为
  #     一谈。
  # 这个正则的 host/user 字符集跟 HOST_FORMAT 一致（含下划线、不含前导
  # 连字符），能匹配到这里、又没有被 valid_host? 判定为合法的字符串，
  # 必然是因为带了 user@ 前缀或 :port 后缀（否则早被 HOST_FORMAT 认下
  # 了），所以不需要额外判断"是不是真的带了 user/port"。
  HOST_WITH_USER_OR_PORT_FORMAT = /\A(?:(?!-)[A-Za-z0-9_.-]{1,64}@)?(?!-)[A-Za-z0-9_.-]{1,255}(?::[0-9]{1,5})?\z/

  # ssh.proxy 的格式：可选的 "user@"，一个 host（复用上面 HOST_FORMAT
  # 的字符集：字母数字、点、下划线、连字符，不允许以连字符开头），可选的
  # ":port"。user 部分同样不允许以连字符开头（"-F@host" 这种虽然目前
  # 拼不出可利用的命令——getopt 会把它当成 -l 的参数值吞掉，且 "="、
  # 空格都已经被字符集排除——但参数注入距离命令注入只有一步之遥，跟
  # host 用同一条规则更一致，成本也是一个字符类）。这是刻意收紧过的
  # 字符集，不是"随便写的正则"：
  #
  # - 不允许逗号。Net::SSH::Proxy::Jump#build_proxy_command_equivalent 里
  #   `jump_proxies.split(",", 2)` 之后的 extra_jumps 部分会被原样拼进
  #   一条要交给 IO.popen 执行的 shell 命令字符串，从不经过 URI 解析或转义——
  #   这是本类要堵住的注入点，所以逗号在第一步就被拒绝，根本不进入下面的
  #   字符集校验。
  # - user/host 都不允许空白、分号、管道、`$(`、反引号等 shell 特殊
  #   字符——同样是因为最终会有一部分内容原样进入 shell 命令行
  #   （-l/-p/主机名部分），字符集就是唯一的防线。
  # - 只支持单跳：这是当前版本的产品决定，不是"以后再补"的限制——多跳
  #   （`-J extra_jumps`）那部分正是不做 URI 解析、直接拼接的部分。
  # - 这里没有像 servers: 主机名那样支持 IPv6——round 5 review 报告
  #   的证据只覆盖了 servers:，没有证据表明 ssh.proxy 需要 IPv6 跳板机；
  #   在没有具体需求的情况下扩大这里的字符集只是无谓的复杂度。
  PROXY_FORMAT = /\A(?:(?<user>(?!-)[A-Za-z0-9_.-]{1,64})@)?(?<host>(?!-)[A-Za-z0-9_.-]{1,255})(?::(?<port>[0-9]{1,5}))?\z/

  # 1-65535，纯数字。Kamal 自己的文档示例里 port 就写成字符串
  # `"2222"`——ssh.port 不保证是 Integer，YAML 里怎么写、Kamal 就怎么
  # 原样交出来（Kamal::Configuration::Ssh#port 只是 `fetch("port", 22)`，
  # 不做任何类型/格式校验）。这个值最终会被 Net::SSH::Proxy::Jump 拼进
  # `-p #{uri.port}` 这段 shell 命令行——`"22 ; id #"` 这种 payload
  # 如果不在这里挡住，就是又一条命令注入路径。
  PORT_FORMAT = /\A[1-9][0-9]{0,4}\z/

  def self.call(yaml:, destination: nil, destination_yaml: nil, timeout: DEFAULT_TIMEOUT)
    new(yaml:, destination:, destination_yaml:, timeout:).call
  end

  def initialize(yaml:, destination:, destination_yaml:, timeout:)
    @yaml = yaml
    @destination = destination
    @destination_yaml = destination_yaml
    @timeout = timeout
  end

  def call
    Dir.mktmpdir(TMPDIR_PREFIX) do |dir|
      write_config_files(dir)

      result = JSON.parse(run_subprocess(dir))
      raise ParseError, result["error"] unless result["ok"]

      validate_service!(result["service"])
      validate_hosts!(result)
      result["ssh_options"] = build_ssh_options(result["ssh_options"])

      Kamal::ParsedConfig.new(result)
    end
  rescue JSON::ParserError => e
    raise ParseError, "子进程返回了无法解析的输出：#{e.message}"
  end

  private
    attr_reader :yaml, :destination, :destination_yaml, :timeout

    def write_config_files(dir)
      config_path(dir).write(yaml)

      # Kamal 要求：只要传了 destination，就必须存在一个
      # "<config>.<destination>.yml" 的目标专属文件，否则
      # Kamal::Configuration.load_config_file 会直接报错文件不存在
      # （configuration.rb 里 load_config_files 对每个文件无条件要求
      # file.exist?）。这个伴随文件不是形式主义——Kamal 会把它
      # deep_merge 到 base 配置之上，真实项目常用它覆盖 servers
      # （即不同 destination 部署到不同的机器）。所以：
      #   - 调用方提供了 destination_yaml，就原样写入，让覆盖生效；
      #   - 没提供（nil / 空字符串），写一个空 Hash 占位，只满足
      #     "文件必须存在" 的约定，不产生任何实际覆盖。
      return if destination.blank?

      validate_destination!
      destination_path(dir).write(destination_yaml.presence || "{}")
    end

    def validate_destination!
      # `destination.is_a?(String) &&` 在前面挡一道：这个类是公开 API，
      # 一个绕过 ManagedApp 的直接调用者完全可能传一个非 String 的
      # destination（比如不小心传了 Integer/Symbol）。裸调用
      # `destination.match?` 对这种输入会抛 NoMethodError——那是本类
      # 内部实现细节泄露出去的异常，调用方接不住；这里应该用本类自己的
      # 词汇（ParseError）来拒绝，而不是让一个 NoMethodError 冒出去。
      return if destination.is_a?(String) && destination.match?(DESTINATION_FORMAT)

      raise ParseError, "destination 不合法：只能是字母、数字、下划线或连字符组成的短标识符（最多 63 个字符），" \
                         "不能包含路径分隔符或点"
    end

    def validate_service!(service)
      # 跟 validate_destination! 同样的理由（见该方法上方的注释）：这是
      # 公开 API，不能假设子进程的输出、或者绕过 ManagedApp 的直接调用者
      # 一定给得出一个合法的 String。
      return if service.is_a?(String) && service.match?(SERVICE_FORMAT)

      raise ParseError, "service 不合法：只能是字母、数字、下划线或连字符组成的短标识符（最多 63 个字符），" \
                         "不能包含路径分隔符或点"
    end

    def config_path(dir)
      Pathname.new(dir).join("deploy.yml")
    end

    # servers: 里的主机名/IP 来自用户粘贴的 deploy.yml，Kamal 自己对它们
    # 只做了 String/Hash 的形状校验（config.roles 里的
    # Kamal::Configuration::Role#hosts），没有任何字符集限制。这些值
    # 后续会被 Collectors::SshSession（本类之外，见那边文件顶部的注释）
    # 以及 Net::SSH::Proxy::Jump 的 `-W %h:%p` 模板拼进要执行的命令行/
    # shell 字符串——如果 host 本身就带着 `; touch ...`、反引号之类的
    # 内容，字符集不收紧的话，第一次建立连接（哪怕只是接入时的连通性
    # 探测）就会执行任意命令。校验放在这里而不是等到 SshSession 使用
    # 它的那一刻，原因和 destination/ssh.proxy 一样：ConfigParser 是
    # 公开 API，后续任务会直接拿 app_hosts/roles[*][:hosts] 用，不能
    # 假设调用方会先自己查一遍字符集。
    def validate_hosts!(result)
      hosts = Array(result["app_hosts"]).dup
      hosts << result["primary_host"] if result["primary_host"]
      Array(result["roles"]).each { |role| hosts.concat(Array(role["hosts"])) }

      hosts.uniq.each do |host|
        next if valid_host?(host)

        if host.is_a?(String) && (HOST_WITH_USER_OR_PORT_FORMAT.match?(host) || valid_bracketed_ipv6?(host))
          raise ParseError, "servers 里的 #{host.inspect} 暂不支持：面板目前还不支持在 servers: 里给" \
                             "单台主机单独指定 user 或 port（SSHKit 的 user@host / host:port /" \
                             "user@host:port 写法）。这不是配置错误——如果需要覆盖，请暂时写在" \
                             "ssh: 段（对所有主机生效）；每台主机单独覆盖是计划中的后续功能。"
        end

        raise ParseError, "servers 里的主机名/IP 不合法（#{host.inspect}）：只能是 IPv4/主机名" \
                           "（字母、数字、点、下划线、连字符，不能以连字符开头），或裸 IPv6 地址" \
                           "（不带方括号、不带端口，如 \"::1\"）"
      end
    end

    # servers: 里一台主机合法的全部形状：IPv4/主机名（HOST_FORMAT）、裸
    # IPv6。刻意不包含 user@host、host:port、user@host:port，也不包含
    # 方括号 IPv6（带或不带端口）——SSHKit 的主机解析器认得前三种写法
    # （每台主机各自的 user/port 覆盖全局 ssh: 段），但面板目前的
    # SshSession 只有一份全局 user/port，没有"每台主机各自覆盖"这个功能。
    # 方括号 IPv6 被拒绝是另一个原因：解析器（本类）接受它没问题，但
    # 下游没有任何代码会把方括号剥掉、把端口拆出来——SshSession#connect
    # 把裸字面量原样交给 Net::SSH.start → Socket.tcp，那两者都不认识
    # "[::1]"或"[::1]:2222"这种写法，结果是校验通过、连接却诡异地失败。
    # 支持这两类都不是收紧/放宽字符集就能做到的——被解析出来的 host 部分
    # 得单独传给 Net::SSH.start，每台主机各自的 user/port（或者方括号
    # 拆出来的 port）得能覆盖 ssh: 的默认值，SshSession 得能携带这份
    # 结构——这是一次行为改动，值得单独一个任务，不该塞在这一轮的尾巴上。
    # 所以这里的策略是：识别出"看起来像是想用这个功能"的输入
    # （validate_hosts! 里 HOST_WITH_USER_OR_PORT_FORMAT / 方括号 IPv6 那两个
    # 分支），给一句诚实的报错，而不是拿"字符集不对"这种听起来像是"你的
    # 配置写错了"的报错来搪塞——那样会让一份对 Kamal 而言完全合法的
    # deploy.yml 被面板误判成语法错误。
    def valid_host?(host)
      return false unless host.is_a?(String)

      HOST_FORMAT.match?(host) || valid_ipv6?(host)
    end

    def valid_ipv6?(address)
      return false if address.include?(IPV6_ZONE_ID)

      Resolv::IPv6::Regex.match?(address)
    end

    def valid_bracketed_ipv6?(host)
      match = BRACKETED_IPV6_FORMAT.match(host)
      return false unless match
      return false unless valid_ipv6?(match[:addr])
      return true if match[:port].nil?

      match[:port].to_i.between?(1, 65535)
    end

    # bin/parse_deploy_config 只交出 ssh: 段的原始字符串（不构造任何
    # Net::SSH 对象——见该脚本里的注释）。真正的校验和对象构造在这里、
    # 在父进程里完成：这个方法本身不涉及 ERB / YAML.unsafe_load，用
    # 户粘贴的 deploy.yml 内容此刻早已被子进程解析成安全的标量值，
    # 所以可以放心留在主进程做。
    def build_ssh_options(raw_ssh_options)
      # ssh.proxy_command 的语义就是"本地执行这个命令"（Net::SSH::Proxy::Command
      # 最终会 IO.popen 它），这条路径没有安全的校验方式可言——不像
      # ssh.proxy 那样能收紧到一个 [user@]host[:port] 的字符集，
      # proxy_command 的全部意义就是任意命令行。这是一个永久的产品决定，
      # 不是 v1 的临时限制：面板永远不会执行配置文件里指定的本地命令。
      if raw_ssh_options["proxy_command_present"]
        raise ParseError, "ssh.proxy_command 不受支持：面板拒绝执行配置文件里指定的本地命令。" \
                           "如果需要经跳板机连接，请改用 ssh.proxy（格式：[user@]host[:port]，仅支持单跳）。"
      end

      {
        "user" => raw_ssh_options["user"],
        "port" => build_port(raw_ssh_options["port"]),
        "proxy" => build_proxy(raw_ssh_options["proxy"])
      }
    end

    def build_port(raw_port)
      str = raw_port.to_s

      unless PORT_FORMAT.match?(str) && str.to_i.between?(1, 65535)
        raise ParseError, "ssh.port 不合法：只能是 1-65535 之间的纯数字端口号（当前值：#{raw_port.inspect}）"
      end

      str.to_i
    end

    def build_proxy(proxy_spec)
      return nil if proxy_spec.blank?

      # 逗号在字符集校验之前单独拒绝：见 PROXY_FORMAT 上方的注释，这是
      # Net::SSH::Proxy::Jump 里 extra_jumps 的注入点，必须第一时间挡住，
      # 不能指望字符集校验顺带覆盖到（字符集里其实并没有排除逗号本身
      # 不出现在 PROXY_FORMAT 允许的字符里，但独立检查更清楚地表达
      # "这是专门针对多跳注入点的拒绝"，而不是普通格式不合法）。
      raise ParseError, "ssh.proxy 不合法：只支持单跳跳板机，不能包含逗号" if proxy_spec.include?(",")

      unless PROXY_FORMAT.match?(proxy_spec)
        raise ParseError, "ssh.proxy 不合法：格式必须是 [user@]host[:port]，" \
                           "且只能使用字母、数字、点、下划线、连字符"
      end

      # 与 Kamal 自己的默认规则保持一致（Kamal::Configuration::Ssh#proxy：
      # `proxy.include?("@") ? proxy : "root@#{proxy}"`）：裸主机名默认
      # 用户是 root。
      jump_spec = proxy_spec.include?("@") ? proxy_spec : "root@#{proxy_spec}"
      Net::SSH::Proxy::Jump.new(jump_spec)
    end

    # 校验完 destination 的字符集之后，这里是最后一道关卡：不管上面的
    # 正则将来会不会被改坏，实际拼出来的文件路径必须仍然落在这次调用
    # 专属的临时目录里——不是"以临时目录的路径开头"（那样 "/tmp/kp-x"
    # 会被误判为落在 "/tmp/kp" 里面），而是"父目录就是这个临时目录本身"。
    # 任何偏离都当成解析失败处理，绝不写入。
    def destination_path(dir)
      path = config_path(dir).sub_ext(".#{destination}.yml")
      expected_dir = Pathname.new(dir).expand_path

      unless path.expand_path.dirname == expected_dir
        raise ParseError, "destination 解析出的路径超出了临时目录范围，已拒绝"
      end

      path
    end

    # 子进程命令。抽成方法（而不是内联在 run_subprocess 里）只是为了让
    # 测试能在子类里覆写它，换成一个故意不读 stdin / 故意立刻退出的假
    # 子进程，从而在不依赖真实 Kamal 解析行为的前提下，验证下面
    # run_subprocess 里的超时/EPIPE 处理本身是对的。生产路径永远是这一份。
    def command
      [ RbConfig.ruby, SCRIPT ]
    end

    def run_subprocess(dir)
      # .presence（而不是原样传 destination）：空字符串必须和 nil 一样
      # 被子进程当成"没有 destination"处理，否则父进程这边（不写伴随
      # 文件，见 write_config_files）和子进程那边（Kamal 判断"有没有
      # destination"用的多半也是一次真值判断，空字符串是真值）就会各自
      # 得出不一致的结论——父进程没写伴随文件，子进程却认为应该有一份，
      # 报"文件不存在"，而不是把空 destination 干净地当成"未指定"处理。
      input = JSON.generate(config_file: config_path(dir).to_s, destination: destination.presence)
      stdout = nil

      # 用户提供的 deploy.yml 内容只经由临时文件路径传入 stdin（config_file
      # 是路径，不是内容本身），从不进入 shell 命令行，因此这里不存在命令
      # 注入面。deploy.yml 本身的任意代码执行风险（ERB + YAML.unsafe_load）
      # 正是通过隔离到该子进程来防御的。
      Open3.popen3(*command) do |stdin, out, err, wait_thread|
        # 写 stdin、读 stdout、读 stderr 三件事都必须放进各自的线程，且都
        # 必须在 wait_thread.join 之前就启动——三者都可能阻塞父进程：
        #
        #   写：这里的 payload（config_file 路径 + destination）现在已经
        #   很小——destination 被 DESTINATION_FORMAT 限制在 63 个字符以内，
        #   deploy.yml 本身的内容从不经过 stdin（只走临时文件路径）。但
        #   "现在够小"不代表这段代码不需要这层保护：跟 SshKeyValidator
        #   保持同一个模式本身就是目的——如果超过操作系统的管道缓冲区
        #   （常见 64KiB）而子进程还没开始读，同步的 stdin.write 会阻塞
        #   父进程，而这个阻塞
        #   发生在 wait_thread.join(timeout) 生效之前，完全不受硬超时
        #   保护——外层再包一层 Timeout.timeout 都拦不住，因为阻塞的线程
        #   从没运行到能被安全打断的地方；对一个提前退出的子进程，父进程
        #   的 stdin.write 还会直接抛出未被捕获的 Errno::EPIPE，变成调用
        #   方看到的一次未处理异常。
        #
        #   读：如果 deploy.yml 里有大量 host/role，子进程写出的 JSON
        #   可能超过管道缓冲区。此时子进程会阻塞在写入上，而我们如果只在
        #   wait_thread.join 之后才去读，就会在子进程真正卡住之前，先被
        #   我们自己的死锁拖到超时——把一次合法的大输入误报成解析失败。
        #
        # 子进程提前退出或者从不读 stdin，都是正常结局（不是我们要抛给
        # 调用方的异常），所以这里只 rescue Errno::EPIPE，不吞别的错误。
        stdin_writer = Thread.new do
          stdin.write(input)
        rescue Errno::EPIPE
          nil
        ensure
          stdin.close
        end

        # 子进程被 SIGKILL/超时打断时，读线程会在半途的 IO 上撞见
        # IOError（"stream closed"之类），这是预期之内的收尾噪音，不是
        # 需要记录的错误，所以吞掉、不让它的 backtrace 混进日志。
        stdout_reader = Thread.new do
          out.read
        rescue IOError
          nil
        end
        stderr_reader = Thread.new do
          err.read
        rescue IOError
          nil
        end

        unless wait_thread.join(timeout)
          Process.kill("KILL", wait_thread.pid)
          wait_thread.join
          stdin_writer.kill
          stdout_reader.kill
          stderr_reader.kill
          raise ParseError, "解析超时（#{timeout} 秒）。deploy.yml 中可能有耗时的 ERB。"
        end

        stdin_writer.join
        stdout = stdout_reader.value
        stderr = stderr_reader.value

        if stdout.blank?
          raise ParseError, "解析子进程无输出。stderr: #{stderr.truncate(500)}"
        end
      end

      stdout
    end
end
