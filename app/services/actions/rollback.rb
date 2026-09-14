module Actions
  # 最小占位：完整实现见 Task 8。`rollback VERSION` 中的 VERSION 是
  # Kamal 的必填位置参数；这里同样走 require_version!，
  # 不允许面板在没有目标版本号时裸调 rollback。
  class Rollback < Base
    def self.confirm_by_name? = true

    def cli_args = [ "rollback", require_version! ]
  end
end
