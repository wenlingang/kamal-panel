module Actions
  # `accessory reboot` removes the container and boots a new one from the (re-pulled) image —
  # a real outage of whatever depends on it, hence the typed-name confirmation.
  class AccessoryReboot < AccessoryAction
    def self.confirm_by_name? = true

    def cli_args = accessory_args("reboot")
  end
end
