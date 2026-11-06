module Actions
  # Undo `maintenance`: kamal-proxy routes requests to the app again.
  class Live < Base
    def cli_args = [ "app", "live", "--version", version_for_lock ]
  end
end
