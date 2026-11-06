module Actions
  # `app boot` always gets the running version explicitly (require_version!);
  # otherwise Kamal would try to derive the version number from git and fail.
  class Restart < Base
    # Optional: one of the app's hosts, to restart there only (--hosts).
    def self.target_kind = :host

    def cli_args
      args = [ "app", "boot", "--version", require_version! ]
      args += [ "--hosts", validated_target ] if target
      args
    end

    def affected_hosts = target ? [ target ] : super
  end
end
