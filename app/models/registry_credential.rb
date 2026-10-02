class RegistryCredential < ApplicationRecord
  include WriteOnlySecret

  has_many :managed_apps, dependent: :restrict_with_error, inverse_of: :registry_credential

  # The panel assembles the password into a line `<variable name>='<password>'` in
  # .kamal/secrets-common.
  validates :value, format: {
    without: /['\n\r]/,
    message: :no_quotes_or_newlines
  }, allow_blank: true
end
