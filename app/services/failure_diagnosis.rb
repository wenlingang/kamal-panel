# Reads the output of a failed kamal run and names the most likely cause in plain words, with what
# to do about it and, where there is one, a command to copy. A table of patterns, not a parser: kamal
# wraps whatever docker, ssh, the registry or the app's own build printed, so the useful line can be
# anywhere and in anyone's wording.
#
# Only the tail is read: the error is near the end, and earlier lines (a long build log) are more
# likely to match something that was only a warning. Rules are tried in order and the first match
# wins, so the narrow ones come before the broad ones.
#
# The result is stored on the audit row (AuditLog#diagnosis) as { "key" => ..., "args" => {...} };
# the words live in the locale files (failure_diagnosis.<key>.cause / .fix), the command here, since
# a command is the same in every language.
module FailureDiagnosis
  TAIL_LINES = 120

  Rule = Data.define(:key, :pattern, :command, :args)

  # args: a lambda that pulls the named details out of the match (a host, a secret's name).
  def self.rule(key, pattern, command: nil, args: nil) = Rule.new(key:, pattern:, command:, args:)

  RULES = [
    rule("timed_out", /\[面板\] 执行超时|\[panel\] timed out/),
    rule("deploy_lock", /Deploy lock (?:found|already in place)|deploy lock is held/i,
         command: "kamal lock status"),

    # Reaching the hosts.
    rule("host_key_mismatch", /HostKeyMismatch|fingerprint .* does not match|REMOTE HOST IDENTIFICATION HAS CHANGED/i,
         command: "ssh-keygen -R <host>"),
    rule("ssh_auth", /Authentication failed for user (\S+)|Net::SSH::AuthenticationFailed|Permission denied \(publickey/i,
         args: ->(match) { { "user" => match[1].to_s } }),
    rule("ssh_unreachable", /Net::SSH::ConnectionTimeout|Errno::(?:ECONNREFUSED|EHOSTUNREACH|ENETUNREACH|ETIMEDOUT)|Connection refused - connect\(2\)|connect\(2\) for .* \(Errno|getaddrinfo: (?:nodename nor servname|Name or service not known)/i),

    # Docker on the host.
    rule("docker_missing", /docker: (?:command )?not found|Failed to find executable docker|bash: docker:/i,
         command: "curl -fsSL https://get.docker.com | sh"),
    rule("docker_permission", /permission denied while trying to connect to the Docker daemon/i,
         command: "sudo usermod -aG docker $USER"),
    rule("docker_daemon_down", /Cannot connect to the Docker daemon|Is the docker daemon running/i,
         command: "sudo systemctl start docker"),
    rule("disk_full", /no space left on device/i, command: "docker system prune"),

    # The registry and the image.
    rule("registry_rate_limit", /toomanyrequests|reached your (?:unauthenticated )?pull rate limit/i),
    rule("registry_auth", /unauthorized: (?:authentication required|incorrect username or password)|incorrect username or password|denied: requested access to the resource is denied|no basic auth credentials|Error response from daemon: (?:Get|Head) .*: unauthorized/i,
         command: "kamal registry login"),
    rule("image_missing", /manifest unknown|manifest for \S+ not found|not found: manifest|pull access denied|repository does not exist or may require/i),

    # Configuration and secrets.
    rule("secret_missing", /Secret ['"]?([\w.-]+)['"]? not found|missing secret[: ]+['"]?([\w.-]+)|KeyError.*key not found: :?"?([A-Z][A-Z0-9_]+)/i,
         args: ->(match) { { "name" => match.captures.compact.first.to_s } }),

    # Starting the new version.
    rule("port_in_use", /port is already allocated|address already in use|EADDRINUSE/i, command: "ss -ltnp"),
    rule("out_of_memory", /OOMKilled|JavaScript heap out of memory|Cannot allocate memory|exit(?:ed| code:?) 137\b/i),
    rule("health_check_failed", /target failed to become healthy|failed to become healthy|HealthcheckError|container not healthy|is not healthy/i,
         command: "kamal app logs"),
    rule("container_exited", /container (?:\S+ )?(?:exited|is not running)|exited with code [1-9]/i,
         command: "kamal app logs"),

    # Building the image (when the deploy builds instead of taking a pushed version).
    rule("buildx_missing", /buildx (?:component is missing|isn't installed)|docker: 'buildx' is not a docker command|unknown command: docker buildx/i),
    rule("build_copy_missing", /failed to compute cache key|COPY failed|failed to calculate checksum of ref .*not found/i),
    rule("build_npm_lock", /can only install packages when your package\.json and package-lock\.json|npm ci.* can only install with an existing package-lock/im),
    rule("build_npm_script", /Missing script: "?build"?/i),
    rule("build_runtime_version", /The engine "node" is incompatible|Unsupported engine|requires Node\.js|requires php [^\n]*your php version|Root composer\.json requires php|requires Ruby version|Your Ruby version is \S+, but your Gemfile specified/i),
    rule("build_dependencies", /Your requirements could not be resolved|No matching distribution found for|Could not find a version that satisfies the requirement|Could not find gem|Bundler could not find compatible versions/i),

    # Network from the host or the builder.
    rule("network", /Could not resolve host|Temporary failure in name resolution|getaddrinfo (?:EAI_AGAIN|ENOTFOUND)|Network is unreachable|TLS handshake timeout|i\/o timeout/i)
  ].freeze

  KEYS = RULES.map(&:key).freeze

  module_function

  # { "key" => "...", "args" => {...} } for the first rule the tail of the output matches; nil when
  # none does (the output is then all there is to go on).
  def call(output)
    tail = output.to_s.lines.last(TAIL_LINES).join

    RULES.each do |rule|
      match = rule.pattern.match(tail)
      next unless match

      args = rule.args ? rule.args.call(match).compact_blank : {}
      return { "key" => rule.key, "args" => args }
    end

    nil
  end

  # What a stored diagnosis says, in the reader's language. nil for a key this version doesn't know
  # (a row written by a newer panel, then rolled back).
  def explain(diagnosis, locale: I18n.locale)
    key = diagnosis.to_h["key"].to_s
    rule = RULES.find { |candidate| candidate.key == key }
    return nil if rule.nil?

    # A detail the output didn't name (a secret error without the secret's name) still reads as a
    # sentence instead of raising on the missing interpolation.
    unknown = I18n.t("failure_diagnosis.unknown", locale:)
    args = { name: unknown, user: unknown }.merge(diagnosis.to_h["args"].to_h.symbolize_keys)
    {
      cause: I18n.t("failure_diagnosis.#{key}.cause", **args, locale:, default: ""),
      fix: I18n.t("failure_diagnosis.#{key}.fix", **args, locale:, default: ""),
      command: rule.command
    }
  end
end
