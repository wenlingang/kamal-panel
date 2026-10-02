class AddKamalProjectFilesToManagedApps < ActiveRecord::Migration[8.1]
  # Kamal 把 `.kamal/secrets*` 与 `.kamal/hooks/*` 都按【当前工作目录】相对路径
  # 解析（kamal-2.12.0 configuration.rb:268-273）。面板在临时目录里执行 kamal，
  # 所以这两样东西必须由面板自己持有并写进那个临时目录，否则用户的 hook 永远
  # 不会触发、`app boot`/`rollback` 在标准的数组式密码写法上必然失败。
  #
  # 两列都加密：secrets 顾名思义；hooks 脚本按 spec 5.4 的样例本身就带
  # per-application token，同样是凭据材料。
  def change
    add_column :managed_apps, :kamal_secrets, :text
    add_column :managed_apps, :kamal_hooks, :text
  end
end
