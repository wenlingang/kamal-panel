module Actions
  # otherwise Kamal would try to derive the version number from git and fail.
  class Restart < Base
    def cli_args = [ "app", "boot", "--version", require_version! ]
  end
end
