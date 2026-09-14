# 「这个人能动哪几个应用」。只对 developer 生效——admin 与 ops 的权限来自
# 全站角色，永远不进这张表（往里加只会制造「有两个地方决定 admin 能不能动
# 这个应用」的假象）。
#
# 这张表上【没有角色列】，也不该有：加一列 role 就等于把模型变成「每个应用
# 上各自一个角色」，那是设计 11 第 1.1 节明确否掉的方案。真要那样改，是一次
# 显式的模型变更，不该由谁往这张表上悄悄加一列来完成。
class AppMembership < ApplicationRecord
  belongs_to :user
  belongs_to :managed_app
end
