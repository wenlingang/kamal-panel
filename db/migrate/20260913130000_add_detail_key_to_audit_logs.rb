class AddDetailKeyToAuditLogs < ActiveRecord::Migration[8.1]
  # 审计行只增不删，历史行里的 detail 是当时拼好的中文串，没法回溯翻译。
  # 所以不改 detail，也不回填：新列只管新行，老行继续走 detail 原样显示。
  #
  # detail 因此有了明确分工：它装【不需要翻译的对象文本】——凭据名、应用名
  # 这类专名，翻译了反而是错的——以及所有历史行。detail_key 装可翻译的那一类。
  def change
    add_column :audit_logs, :detail_key, :string
    add_column :audit_logs, :detail_args, :text
  end
end
