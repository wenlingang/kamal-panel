require "net/ssh"
require "shellwords"

module FakeHost
  NODES = { "node-1" => 2201, "node-2" => 2202 }.freeze
  KEY_PATH = Rails.root.join("test/fake_host/id_ed25519")
  PROXY_IMAGE = "basecamp/kamal-proxy:v0.10.0".freeze

  class NotReady < StandardError; end

  # git only preserves the executable bit, so this test key is 0644 when checked out of the repo,
  # and the OpenSSH client [refuses] to use a private key that is group/world readable. Tests going
  # through net-ssh (Ruby) are unaffected -- it doesn't do this OS check -- but any test calling the
  # real ssh / kamal binary fails with "Permission denied (publickey)", and the failure message
  # doesn't point to permissions at all. The CI workflow has a chmod 600 step for exactly this;
  # local development has no such step, so it's fixed up automatically here.
  def self.ensure_key_mode!
    mode = File.stat(KEY_PATH).mode & 0o777
    File.chmod(0o600, KEY_PATH) unless mode == 0o600
  end

  def self.private_key
    File.read(KEY_PATH)
  end

  def self.ssh_options
    {
      keys: [ KEY_PATH.to_s ],
      keys_only: true,
      auth_methods: [ "publickey" ],
      verify_host_key: :never,
      timeout: 5
    }
  end

  def self.ssh(node, command)
    port = NODES.fetch(node)
    Net::SSH.start("127.0.0.1", "deploy", **ssh_options, port: port) do |session|
      session.exec!(command).to_s
    end
  end

  # Memoize readiness -- but only "success". Once the fake host is ready, it won't drop mid-run
  # during a test process, so there's no need for every test to open 2 SSH connections for it; but
  # if the container hasn't started on the first probe, this "temporarily not ready" must not be
  # permanently memoized as failure, otherwise when the container starts late in local development
  # it would keep falsely reporting the fixture as broken. So the failure branch re-probes every
  # time.
  def self.ready?
    return true if @ready

    NODES.each_key do |node|
      # `ssh` (net-ssh's exec!) does not surface the remote command's exit
      # status, so we can't rely on "docker info >/dev/null && echo ok"
      # raising when docker info fails — we have to check the actual output.
      raise NotReady unless ssh(node, "docker info >/dev/null && echo ok").strip == "ok"
    end
    @ready = true
  rescue StandardError
    false
  end

  def self.ensure_ready!
    ensure_key_mode!
    return if ready?

    raise NotReady, <<~MSG
      fake host 未就绪。请先启动：
        docker compose -f docker-compose.test.yml up -d --build
    MSG
  end

  # Probe a single node directly, without going through or writing the @ready "everyone only needs
  # to succeed once" memoization flag. Fault-injection tests really stop a node and bring it back
  # up, and at that point what needs answering is "is this one reachable right now", while #ready?
  # returns true forever once it has seen one success (even while this node is restarting), so using
  # it to judge "has it recovered after restart" would be plainly distorted.
  def self.node_ready?(node)
    ssh(node, "docker info >/dev/null && echo ok").strip == "ok"
  rescue StandardError
    false
  end

  def self.wait_until_node_ready!(node, timeout: 60)
    deadline = Time.now + timeout
    until node_ready?(node)
      raise NotReady, "#{node} 在 #{timeout} 秒内未能恢复就绪" if Time.now > deadline
      sleep 1
    end
  end

  # Build a container following Kamal's naming and label conventions. The container name format
  # comes from Kamal::Configuration::Role#container_name:
  #   [service, role, destination].compact.join("-") + "-" + version
  #
  # These parameters (especially service/destination/role) are spliced into a command sent over SSH
  # to be run by the remote shell -- currently all callers pass literals, none from untrusted input,
  # so today it is not an injection surface; but this helper is the template Tasks 6-8 will all
  # copy, and if they later pass in ManagedApp fields (even an already validated destination), then
  # "this should have been escaped here" shouldn't be something you only know by reading this code.
  # So whether or not it is needed today, escape every value spliced into the command line with
  # Shellwords.escape.
  def self.seed_container(node:, service:, role:, destination:, version:, state: :running)
    name = [ service, role, destination, version ].compact.join("-")

    escaped_name = Shellwords.escape(name)
    escaped_service = Shellwords.escape(service)
    escaped_destination = Shellwords.escape(destination.to_s)
    escaped_role = Shellwords.escape(role)

    ssh node, <<~SH
      docker run -d --name #{escaped_name} \
        --label service=#{escaped_service} \
        --label destination=#{escaped_destination} \
        --label role=#{escaped_role} \
        busybox:latest sleep 3600
    SH

    ssh(node, "docker stop #{escaped_name}") if state == :stopped

    name
  end

  def self.start_proxy(node)
    ssh node, <<~SH
      docker run -d --name kamal-proxy \
        --restart unless-stopped \
        --publish 8080:80 \
        #{Shellwords.escape(PROXY_IMAGE)}
    SH

    # Wait for the proxy's RPC socket to be ready
    20.times do
      return if ssh(node, "docker exec kamal-proxy kamal-proxy list --json 2>/dev/null").present?
      sleep 0.5
    end

    raise NotReady, "kamal-proxy 在 #{node} 上未能就绪"
  end

  def self.proxy_deploy(node:, service:, target:)
    escaped_service = Shellwords.escape(service)
    escaped_target = Shellwords.escape(target)

    ssh node, "docker exec kamal-proxy kamal-proxy deploy #{escaped_service} --target #{escaped_target} --force"
  end

  def self.reset!(node)
    ssh node, "docker ps -aq | xargs -r docker rm -f"
  end

  def self.reset_all!
    NODES.each_key { |node| reset!(node) }
  end
end
