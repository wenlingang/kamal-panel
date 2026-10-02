module Actions
  class Logs < Base
    LINES = 200

    def self.requires_lock? = false
    def self.mutating?      = false

    def cli_args = [ "app", "logs", "--lines", LINES.to_s ]
  end
end
