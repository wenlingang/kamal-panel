# 先写后做（spec 7.5）：动作发起前就落一条 pending，执行完再更新。
# 面板中途崩溃时也留下「有人发起过这个操作」的痕迹——
# 事后追查时，「没有记录」与「记录显示中断」是完全不同的信息量。
class AuditLog < ApplicationRecord
  belongs_to :user
  # 权限变更不属于任何应用（见迁移 AllowSiteWideAuditLogs）。
  belongs_to :managed_app, optional: true
  # 被操作的人。动作类审计没有这个值，人员类审计必有。
  belongs_to :target_user, class_name: "User", optional: true

  RESULTS = %w[pending success failure].freeze

  # 权限类动作名此前是散在各控制器里的字符串字面量，没有任何地方登记，
  # 也就没法回答"是不是每个动作都有译文"。这份清单存在的理由就是让那条
  # 覆盖测试成立——它【不】用来校验 action_name：拒绝一个没登记的动作名
  # 是另一回事，那会让历史上改过名的行写不进来。
  ACCESS_ACTIONS = %w[
    user.create user.update_role user.deactivate user.reactivate
    app.add_member app.remove_member app.update app.deactivate app.reactivate
    credential.create credential.rotate credential.delete
    registry_credential.create registry_credential.rotate registry_credential.delete
  ].freeze

  # 部署动作的名字由封闭动作集自己定义，不在这里重抄一遍。
  def self.all_action_names = Actions::Base.registry.keys + ACCESS_ACTIONS

  validates :action_name, presence: true
  validates :result, inclusion: { in: RESULTS }

  serialize :hosts, coder: JSON, type: Array
  # 可翻译对象的插值参数。默认 {} 而不是 nil，省得每个读它的地方各写一次判空。
  serialize :detail_args, coder: JSON, type: Hash

  # 审计日志不可删除，UI 也不提供删除入口。
  def destroy = raise(ActiveRecord::ReadOnlyRecord, "审计日志不可删除")
  def delete  = raise(ActiveRecord::ReadOnlyRecord, "审计日志不可删除")

  # destroy/delete 只挡得住「先取出一个实例再删」的路径。delete_all（以及靠它实现的
  # delete、delete_by——见 ActiveRecord::Relation 源码）是直接拼 SQL DELETE，压根不
  # 实例化对象，上面两个方法覆盖形同虚设。这里把 delete_all 在 Relation /
  # AssociationRelation / CollectionProxy 三个关系类上都封死，堵住类级和 relation 级
  # 的调用（`AuditLog.delete_all`、`AuditLog.where(...).delete_all`、
  # `AuditLog.delete(id)`、`AuditLog.delete_by(...)`，以及将来若给 ManagedApp/User
  # 加上 `has_many :audit_logs` 后 `some_app.audit_logs.delete_all` 这条路）。
  #
  # 这堵不住的口子，写在这里而不是留给读者猜：
  #   - 绕开 ActiveRecord、直接对 sqlite3 文件下 DELETE（例如用 sqlite3 CLI 或另一个
  #     进程用 ActiveRecord::Base.connection.execute("DELETE FROM audit_logs ...")）；
  #   - 一次未来的迁移里手写 `execute("DELETE ...")` 或 `drop_table :audit_logs`；
  #   - 直接改 db/*.sqlite3 文件本身。
  # 这些都发生在模型的势力范围之外，模型挡不住，只能靠代码审查、迁移审查和数据库访问
  # 权限本身去挡。
  [
    ActiveRecord::Relation,
    ActiveRecord::AssociationRelation,
    ActiveRecord::Associations::CollectionProxy,
    ActiveRecord::DisableJoinsAssociationRelation
  ].each do |relation_class|
    relation_delegate_class(relation_class).class_eval do
      def delete_all(*)
        raise ActiveRecord::ReadOnlyRecord, "审计日志不可删除"
      end
    end
  end

  def self.start!(user:, managed_app:, action_name:, target_version:, hosts:)
    create!(user:, managed_app:, action_name:, target_version:, hosts: Array(hosts),
            result: "pending", created_at: Time.current)
  end

  # 权限变更是当场完成的，没有「执行中」这个阶段——所以它不像 start! 那样
  # 留一条 pending 等 finish! 来收尾，而是直接写成已完成。
  # managed_app 与 managed_app_id 两个都收：成员变更时调用方手上只有 id
  # （来自表单勾选），为了凑出记录再查一次应用是白花的一次查询。
  # detail 与 detail_key 是对象列的两条路，互斥：detail 装不需要翻译的文本
  # （凭据名、应用名这类专名），detail_key 装要按当前语言渲染的那一类。
  def self.record_access!(user:, action_name:, target_user: nil,
                          managed_app: nil, managed_app_id: nil, detail: nil,
                          detail_key: nil, detail_args: nil)
    # managed_app_id 只在没有明确传入时才回退到 managed_app 的 id——两个都传给
    # create! 的话，后写的 managed_app_id: nil 会覆盖掉先写的 managed_app 关联。
    managed_app_id ||= managed_app&.id
    create!(user:, action_name:, target_user:, managed_app_id:, detail:,
            detail_key:, detail_args: detail_args || {}, hosts: [],
            result: "success", created_at: Time.current, finished_at: Time.current)
  end

  def finish!(result:, command:, output_digest:, duration_ms:)
    unless RESULTS.include?(result)
      raise ArgumentError, "无效的 result：#{result.inspect}（必须是 #{RESULTS.join('/')}之一）"
    end

    # 校验先做完再落库——不会出现「先写了一半，校验才发现不对」的中间状态。
    update_columns(result:, command:, output_digest: output_digest.to_s.truncate(4000),
                   duration_ms:, finished_at: Time.current)
  end
end
