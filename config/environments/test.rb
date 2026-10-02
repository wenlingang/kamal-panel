# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show full error reports.
  config.consider_all_requests_local = true
  config.cache_store = :memory_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.
  config.active_storage.service = :test

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "example.com" }

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # 漏翻就红，而不是在页面上渲染成 "translation missing"。
  #
  # 注意它和 config.i18n.fallbacks = [ :en ] 的配合：缺中文译文时 i18n 会
  # 静默退回英文，【不会】触发这个 raise。所以这一条只拦得住「中英都缺」，
  # 而「有中文没英文」要靠 LocaleSmokeTest 在 :en 下真的渲染一遍才抓得到。
  # 两者缺一不可。
  config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # 固定的测试专用 Active Record encryption 密钥（由 `bin/rails db:encryption:init`
  # 生成）。它们只保护测试数据库里的测试数据，和本仓库已提交的 fake-host SSH 私钥
  # （test/fake_host/id_ed25519）性质相同：不是生产密钥，落盘无风险。
  # CI 改用环境变量注入（见 .github/workflows/ci.yml 的 test job），本地
  # `bin/rails test` 不设置这些环境变量时会退回到这里的兜底值。
  config.active_record.encryption.primary_key = ENV.fetch("AR_ENCRYPTION_PRIMARY_KEY", "XPpmaOuyW56x2nZ4gfpW8EALrCI6UJvI")
  config.active_record.encryption.deterministic_key = ENV.fetch("AR_ENCRYPTION_DETERMINISTIC_KEY", "okmI399J9IkfdN2ckeGjcbTD6FkoxUiG")
  config.active_record.encryption.key_derivation_salt = ENV.fetch("AR_ENCRYPTION_KEY_DERIVATION_SALT", "XIZeEdvc2kyN0Epin1RzAzEPw1ADq8DH")
end
