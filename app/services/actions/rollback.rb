module Actions
  class Rollback < Base
    def self.confirm_by_name? = true
    def self.requires_version? = true
    def self.records_deploy_event? = true

    def cli_args = [ "rollback", require_version! ]
  end
end
