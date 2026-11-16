class AddDiagnosisToAuditLogs < ActiveRecord::Migration[8.1]
  def change
    # FailureDiagnosis's verdict on a failed run: { "key" => ..., "args" => {...} }, as JSON.
    add_column :audit_logs, :diagnosis, :text
  end
end
