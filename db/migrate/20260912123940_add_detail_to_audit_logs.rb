class AddDetailToAuditLogs < ActiveRecord::Migration[8.1]
  def change
    # 一句人读的"针对谁/针对什么"。设计 11 加的 target_user_id 只能指用户，
    # 而凭据不是用户。凭据事件用它记凭据名。
    add_column :audit_logs, :detail, :string
  end
end
