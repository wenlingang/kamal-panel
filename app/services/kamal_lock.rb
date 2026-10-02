# Read Kamal's own deploy lock (spec 7.4).
class KamalLock
  LOCK_PRESENT_MARKER = "KAMAL_PANEL_LOCK_PRESENT"
  LOCK_ABSENT_MARKER  = "KAMAL_PANEL_LOCK_ABSENT"

  def initialize(managed_app)
    @managed_app = managed_app
  end

  def status
    result = session.capture_many([ primary_host ]) { read_command }.fetch(primary_host)

    # When unreachable, [never report "unlocked"]: that would let the panel allow an operation it
    # has no authority to confirm.
    return { locked: false, details: nil, error: result.error } if result.error

    # The decision signal looks only at the first line; the payload (lock-holder info,
    # attacker-controllable free text) never takes part in the decision. The payload is
    # attacker-controllable free text and never takes part in the decision — otherwise a lock
    # message containing the LOCK_ABSENT substring could fool it.
    marker, _separator, payload = result.stdout.to_s.partition("\n")

    if marker == LOCK_ABSENT_MARKER
      { locked: false, details: nil, error: nil }
    else
      { locked: true, details: payload.strip.presence, error: nil }
    end
  end

  private
    attr_reader :managed_app

    def session = Collectors::SshSession.new(managed_app)

    def primary_host = managed_app.parsed_config.primary_host

    def lock_dir
      name = [ "lock", managed_app.service, managed_app.destination ].compact.join("-")
      ".kamal/#{name}"
    end

    def read_command
      dir = Shellwords.escape(lock_dir)
      "if [ -d #{dir} ]; then " \
        "echo #{LOCK_PRESENT_MARKER}; " \
        "cat #{dir}/details 2>/dev/null | base64 -d 2>/dev/null; " \
      "else " \
        "echo #{LOCK_ABSENT_MARKER}; " \
      "fi"
    end
end
