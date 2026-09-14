class RegistryCredential < ApplicationRecord
  include WriteOnlySecret

  has_many :managed_apps, dependent: :restrict_with_error, inverse_of: :registry_credential

  # 密码会被面板拼成 .kamal/secrets-common 里的一行 `<变量名>='<密码>'`。
  # dotenv 的单引号形式对单引号和换行都没有可用的转义——写进去要么让文件
  # 从这里断开、要么把后面的字节变成别的变量，而失败现场（部署时拉不动镜像）
  # 离原因很远。在人还能改的时候拒绝，而不是在运行时凑合。
  validates :value, format: {
    without: /['\n\r]/,
    message: :no_quotes_or_newlines
  }, allow_blank: true
end
