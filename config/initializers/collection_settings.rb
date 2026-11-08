# Load and validate the collection settings (config/collection.yml + the deployer's overrides) at
# boot, so a typo or an out-of-range value stops the deploy's health check instead of surfacing as
# an error in some job minutes later.
Rails.application.config.after_initialize do
  CollectionSettings.current
end
