module Actions
  # Deploy a version CI has already built and pushed (spec 6). --skip-push makes Kamal pull the
  # image on the hosts instead of building it: the panel has no source checkout and never builds.
  class Deploy < Base
    def self.requires_version? = true
    def self.records_deploy_event? = true

    def cli_args = [ "deploy", "--skip-push", "--version", require_version! ]
  end
end
