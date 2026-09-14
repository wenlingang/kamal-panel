module Actions
  # `app boot`——面板的临时目录没有 git 仓库，必须显式带 --version，
  # 否则 Kamal 会尝试从 git 推导版本号并失败。
  class Restart < Base
    def cli_args = [ "app", "boot", "--version", require_version! ]
  end
end
