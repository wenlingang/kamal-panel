source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3", ">= 8.1.3.1"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use sqlite3 as the database for Active Record
gem "sqlite3", ">= 2.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

# Rails 自带的 locale 只有 en。面板界面是中文的，而 time_ago_in_words、
# 校验失败信息这类文案来自 Rails 而不是本仓库的模板——不装这个 gem，
# 它们会以英文混在中文页面里（"less than a minute前"）。
gem "rails-i18n"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
# Kamal 是本项目的核心依赖：直接复用其配置解析与命令生成。
# require: false 是刻意的——kamal 会加载 Thor CLI，我们只在需要时局部 require。
#
# 版本可由 KAMAL_VERSION 覆盖，只为 CI 的兼容矩阵服务（见 .github/workflows/ci.yml）：
# 面板从配置解析、容器标签、锁目录格式到 CLI 参数四处依赖 Kamal 的内部行为，
# 这是"直接引 gem"方案的必付成本，必须在 CI 里自动暴露，而不是等用户报
# "升级 Kamal 后面板全炸"（主设计 9.4）。日常开发与主 test 作业都不设这个变量，
# 走下面这个默认约束与 Gemfile.lock 锁定的版本。
gem "kamal", ENV.fetch("KAMAL_VERSION", "~> 2.12"), require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"

  # SSH client used by the fake host test fixture (test/support/fake_host_helper.rb)
  gem "net-ssh"
end
