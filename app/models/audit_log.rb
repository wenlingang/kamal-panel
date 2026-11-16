# Write first, then act (spec 7.5): a pending row is written before the action starts and updated
# after it finishes.
class AuditLog < ApplicationRecord
  belongs_to :user
  # Permission changes do not belong to any app (see migration AllowSiteWideAuditLogs).
  belongs_to :managed_app, optional: true
  # The person acted upon. Action-type audits do not have this value; people-type audits always do.
  belongs_to :target_user, class_name: "User", optional: true

  RESULTS = %w[pending success failure].freeze

  # No run outlives the CLI timeout. The margin covers agent teardown and waiting in the actions
  # queue, which can be one CLI timeout when every action thread is busy (config/queue.yml). A row
  # still pending after this was cut off (process restarted, job lost) and will never finish.
  INTERRUPTED_AFTER = KamalCli::Invocation::DEFAULT_TIMEOUT * 2 + 5.minutes

  ACCESS_ACTIONS = %w[
    user.create user.update_role user.deactivate user.reactivate user.change_password
    app.add_member app.remove_member app.update app.deactivate app.reactivate
    credential.create credential.rotate credential.delete
    registry_credential.create registry_credential.rotate registry_credential.delete
    git_connection.create git_connection.update git_connection.rotate git_connection.delete
    notification_channel.create notification_channel.update notification_channel.rotate
    notification_channel.delete
    alert_rule.create alert_rule.update alert_rule.delete
    backup_destination.create backup_destination.update backup_destination.rotate backup_destination.delete
    backup_plan.create backup_plan.update backup_plan.delete backup.run backup.download
    alert_silence.create alert_silence.end
  ].freeze

  # Deploy action names are defined by the closed action set itself and are not re-copied here.
  def self.all_action_names = Actions::Base.registry.keys + ACCESS_ACTIONS

  validates :action_name, presence: true
  validates :result, inclusion: { in: RESULTS }

  serialize :hosts, coder: JSON, type: Array
  # Interpolation arguments for translatable objects. Defaults to {} rather than nil, saving every
  # reader from writing its own nil check.
  serialize :detail_args, coder: JSON, type: Hash
  # FailureDiagnosis's verdict on a failed run, nil when it had none (or the run didn't fail).
  serialize :diagnosis, coder: JSON

  # What is kept of a run's output. A failure's error is at the end, so a long output keeps its
  # head and its tail and drops the middle (usually build or pull progress).
  OUTPUT_LIMIT = 4000
  OUTPUT_HEAD = 800

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

  def self.start!(user:, managed_app:, action_name:, target_version:, hosts:, target: nil)
    create!(user:, managed_app:, action_name:, target_version:, target:, hosts: Array(hosts),
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

  def interrupted?
    result == "pending" && created_at < INTERRUPTED_AFTER.ago
  end

  def self.digest(output)
    output = output.to_s
    return output if output.length <= OUTPUT_LIMIT

    marker = "\n…\n"
    output[0, OUTPUT_HEAD] + marker + output[-(OUTPUT_LIMIT - OUTPUT_HEAD - marker.length)..]
  end

  def explained_failure = diagnosis && FailureDiagnosis.explain(diagnosis)

  def finish!(result:, command:, output_digest:, duration_ms:, diagnosis: nil)
    unless RESULTS.include?(result)
      raise ArgumentError, "无效的 result：#{result.inspect}（必须是 #{RESULTS.join('/')}之一）"
    end

    # Finish validation before writing to the DB — there is no intermediate state of "half written,
    # and validation only then finds it wrong".
    update_columns(result:, command:, output_digest: self.class.digest(output_digest),
                   diagnosis:, duration_ms:, finished_at: Time.current)
  end
end
