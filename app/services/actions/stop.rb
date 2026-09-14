module Actions
  class Stop < Base
    def self.confirm_by_name? = true

    def cli_args = [ "app", "stop", "--version", version_for_lock ]
  end
end
