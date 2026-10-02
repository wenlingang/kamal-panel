module Actions
  # Minimal placeholder: see Task 10 for the full implementation.
  class ForceUnlock < Base
    def self.requires_lock? = false
    def self.confirm_by_name? = true

    def cli_args = %w[lock release]
  end
end
