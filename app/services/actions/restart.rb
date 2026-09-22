module Actions
  # 否则 Kamal 会尝试从 git 推导版本号并失败。
  class Restart < Base
    def cli_args = [ "app", "boot", "--version", require_version! ]
  end
end
