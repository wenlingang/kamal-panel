require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module KamalPanel
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # The panel UI is in Chinese, so the strings Rails itself produces (time_ago_in_words,
    # validation error messages, etc.) must be Chinese too; translations come from rails-i18n.
    # fallbacks go here rather than only in production: when a translation is missing, better to
    # fall back to English than to render something like "translation missing" on the page.
    config.i18n.default_locale = :"zh-CN"
    config.i18n.available_locales = [ :"zh-CN", :en ]
    config.i18n.fallbacks = [ :en ]

    # In production, read the Active Record encryption master keys from env vars, never on disk
    # (spec 7.2). In development, `bin/rails credentials:edit` can write them to
    # credentials.yml.enc; the test environment uses the fixed test-only keys in
    # config/environments/test.rb (see the comments in that file).
    config.active_record.encryption.primary_key = ENV["AR_ENCRYPTION_PRIMARY_KEY"] if ENV["AR_ENCRYPTION_PRIMARY_KEY"]
    config.active_record.encryption.deterministic_key = ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"] if ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"]
    config.active_record.encryption.key_derivation_salt = ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"] if ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"]
  end
end
