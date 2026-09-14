module Actions
  # 看日志。与其余五个动作的结构性差别只有一条：它不改变线上状态，因此
  # 不取部署锁——一次正在进行的部署不该因为有人在看日志而被挡住，反过来
  # 也一样。
  #
  # 仍然写审计：谁在什么时候看了哪个应用的日志，本身就是该留痕的事。
  class Logs < Base
    LINES = 200

    def self.requires_lock? = false
    def self.mutating?      = false

    def cli_args = [ "app", "logs", "--lines", LINES.to_s ]
  end
end
