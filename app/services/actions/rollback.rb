module Actions
  class Rollback < Base
    def self.confirm_by_name? = true

    def cli_args = [ "rollback", require_version! ]
  end
end
