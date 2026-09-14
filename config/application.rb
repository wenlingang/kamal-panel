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

    # 面板界面是中文的，所以 Rails 自己产出的文案（time_ago_in_words、
    # 校验失败信息等）也必须是中文——译文由 rails-i18n 提供。
    # fallbacks 放在这里而不是只放 production：缺一条译文时宁可退回英文，
    # 也不要在页面上渲染出 "translation missing" 这种东西。
    config.i18n.default_locale = :"zh-CN"
    config.i18n.available_locales = [ :"zh-CN", :en ]
    config.i18n.fallbacks = [ :en ]

    # 生产环境从环境变量读取 Active Record encryption 主密钥，不落盘（spec 7.2）。
    # 开发环境可用 `bin/rails credentials:edit` 写入 credentials.yml.enc；
    # 测试环境使用 config/environments/test.rb 中固定的测试专用密钥（见该文件注释）。
    config.active_record.encryption.primary_key = ENV["AR_ENCRYPTION_PRIMARY_KEY"] if ENV["AR_ENCRYPTION_PRIMARY_KEY"]
    config.active_record.encryption.deterministic_key = ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"] if ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"]
    config.active_record.encryption.key_derivation_salt = ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"] if ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"]
  end
end
