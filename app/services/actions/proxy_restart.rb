module Actions
  # kamal-proxy is one container per host shared by every app deployed there, so restarting it
  # briefly interrupts other apps too, not just this one. Hence the typed-name confirmation.
  class ProxyRestart < Base
    def self.confirm_by_name? = true

    def cli_args = [ "proxy", "restart", "--version", version_for_lock ]
  end
end
