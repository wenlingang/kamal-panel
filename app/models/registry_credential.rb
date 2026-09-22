class RegistryCredential < ApplicationRecord
  include WriteOnlySecret

  has_many :managed_apps, dependent: :restrict_with_error, inverse_of: :registry_credential

  # 密码会被面板拼成 .kamal/secrets-common 里的一行 `<变量名>='<密码>'`。
  validates :value, format: {
    without: /['\n\r]/,
    message: :no_quotes_or_newlines
  }, allow_blank: true
end
