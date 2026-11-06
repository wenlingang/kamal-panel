module Actions
  # Removes this app's stopped containers beyond retain_containers and its unused images. Versions
  # pruned away can no longer be rolled back to; nothing running is touched.
  class Prune < Base
    def cli_args = [ "prune", "all", "--version", version_for_lock ]

    # prune runs on KAMAL.hosts: app hosts and accessory hosts alike.
    def affected_hosts = managed_app.parsed_config.all_hosts
  end
end
