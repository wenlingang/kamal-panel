module Actions
  # `accessory restart` = stop + start of the existing container; data and container stay.
  class AccessoryRestart < AccessoryAction
    def cli_args = accessory_args("restart")
  end
end
