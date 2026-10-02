module Actions
  class Start < Base
    def cli_args = [ "app", "start", "--version", version_for_lock ]
  end
end
