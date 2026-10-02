module Actions
  # 最小占位：完整实现见 Task 10。
  class ForceUnlock < Base
    def self.requires_lock? = false
    def self.confirm_by_name? = true

    def cli_args = %w[lock release]
  end
end
