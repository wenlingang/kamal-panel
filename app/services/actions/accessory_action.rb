module Actions
  # Shared by the accessory actions: the target is required and names one accessory from the
  # app's own deploy.yml; only that accessory's hosts are touched.
  class AccessoryAction < Base
    def self.target_kind = :accessory
    def self.requires_target? = true

    def affected_hosts
      Array(managed_app.parsed_config.accessory(target)&.dig(:hosts))
    end

    private
      def accessory_args(subcommand)
        [ "accessory", subcommand, validated_target, "--version", version_for_lock ]
      end
  end
end
