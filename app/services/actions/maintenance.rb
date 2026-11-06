module Actions
  # kamal-proxy answers every request with a 503 maintenance page until `live`; the containers keep
  # running. That takes the service offline for users, hence the typed-name confirmation.
  class Maintenance < Base
    def self.confirm_by_name? = true

    def cli_args = [ "app", "maintenance", "--version", version_for_lock ]
  end
end
