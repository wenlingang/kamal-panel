class AddDetailKeyToAuditLogs < ActiveRecord::Migration[8.1]
  # Audit rows are append-only, and detail in historical rows is a Chinese string composed at the
  # time, which can't be translated retroactively. So detail is left alone and not backfilled: the
  # new column covers only new rows, and old rows keep displaying detail as-is.
  #
  # detail thus gets a clear division of labor: it holds [object text that needs no translation]
  # (proper names such as credential names and app names, where translating would actually be wrong)
  # plus all historical rows. detail_key holds the translatable kind.
  def change
    add_column :audit_logs, :detail_key, :string
    add_column :audit_logs, :detail_args, :text
  end
end
