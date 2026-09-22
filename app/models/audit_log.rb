# 先写后做（spec 7.5）：动作发起前就落一条 pending，执行完再更新。
class AuditLog < ApplicationRecord
  belongs_to :user
  # 权限变更不属于任何应用（见迁移 AllowSiteWideAuditLogs）。
  belongs_to :managed_app, optional: true
  # 被操作的人。动作类审计没有这个值，人员类审计必有。
  belongs_to :target_user, class_name: "User", optional: true

  RESULTS = %w[pending success failure].freeze

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

  # destroy/delete 只挡得住"先取出实例再删"。
  # delete_all 直接拼 SQL、不实例化对象，所以在三个关系类上都封死它。
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

  def self.record_access!(user:, action_name:, target_user: nil,
                          managed_app: nil, managed_app_id: nil, detail: nil,
                          detail_key: nil, detail_args: nil)
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
