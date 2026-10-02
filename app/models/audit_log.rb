# Write first, then act (spec 7.5): a pending row is written before the action starts and updated
# after it finishes.
class AuditLog < ApplicationRecord
  belongs_to :user
  # Permission changes do not belong to any app (see migration AllowSiteWideAuditLogs).
  belongs_to :managed_app, optional: true
  # The person acted upon. Action-type audits do not have this value; people-type audits always do.
  belongs_to :target_user, class_name: "User", optional: true

  RESULTS = %w[pending success failure].freeze

  ACCESS_ACTIONS = %w[
    user.create user.update_role user.deactivate user.reactivate
    app.add_member app.remove_member app.update app.deactivate app.reactivate
    credential.create credential.rotate credential.delete
    registry_credential.create registry_credential.rotate registry_credential.delete
  ].freeze

  # Deploy action names are defined by the closed action set itself and are not re-copied here.
  def self.all_action_names = Actions::Base.registry.keys + ACCESS_ACTIONS

  validates :action_name, presence: true
  validates :result, inclusion: { in: RESULTS }

  serialize :hosts, coder: JSON, type: Array
  # Interpolation arguments for translatable objects. Defaults to {} rather than nil, saving every
  # reader from writing its own nil check.
  serialize :detail_args, coder: JSON, type: Hash

  # Audit logs cannot be deleted, and the UI offers no delete entry point.
  def destroy = raise(ActiveRecord::ReadOnlyRecord, "审计日志不可删除")
  def delete  = raise(ActiveRecord::ReadOnlyRecord, "审计日志不可删除")

  # destroy/delete only stop "fetch the instance first, then delete". delete_all assembles SQL
  # directly without instantiating objects, so it is sealed off on all three relation classes.
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
    # with create!, a later managed_app_id: nil would overwrite the earlier managed_app association.
    managed_app_id ||= managed_app&.id
    create!(user:, action_name:, target_user:, managed_app_id:, detail:,
            detail_key:, detail_args: detail_args || {}, hosts: [],
            result: "success", created_at: Time.current, finished_at: Time.current)
  end

  def finish!(result:, command:, output_digest:, duration_ms:)
    unless RESULTS.include?(result)
      raise ArgumentError, "无效的 result：#{result.inspect}（必须是 #{RESULTS.join('/')}之一）"
    end

    # Finish validation before writing to the DB — there is no intermediate state of "half written,
    # and validation only then finds it wrong".
    update_columns(result:, command:, output_digest: output_digest.to_s.truncate(4000),
                   duration_ms:, finished_at: Time.current)
  end
end
