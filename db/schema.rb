# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_06_100300) do
  create_table "alert_events", force: :cascade do |t|
    t.integer "alert_rule_id", null: false
    t.datetime "created_at", null: false
    t.string "dedupe_key"
    t.datetime "fired_at"
    t.datetime "last_notified_at"
    t.integer "managed_app_id", null: false
    t.json "message_args", default: {}, null: false
    t.string "message_key", null: false
    t.datetime "resolved_at"
    t.datetime "started_at", null: false
    t.string "state", null: false
    t.datetime "updated_at", null: false
    t.index ["alert_rule_id", "dedupe_key"], name: "index_alert_events_one_per_source_record", unique: true, where: "dedupe_key IS NOT NULL"
    t.index ["alert_rule_id", "managed_app_id"], name: "index_alert_events_one_open_per_rule_and_app", unique: true, where: "state IN ('pending', 'firing') AND dedupe_key IS NULL"
    t.index ["alert_rule_id"], name: "index_alert_events_on_alert_rule_id"
    t.index ["managed_app_id", "state"], name: "index_alert_events_on_managed_app_id_and_state"
    t.index ["managed_app_id"], name: "index_alert_events_on_managed_app_id"
    t.index ["state", "started_at"], name: "index_alert_events_on_state_and_started_at"
  end

  create_table "alert_rule_channels", force: :cascade do |t|
    t.integer "alert_rule_id", null: false
    t.integer "notification_channel_id", null: false
    t.index ["alert_rule_id", "notification_channel_id"], name: "idx_on_alert_rule_id_notification_channel_id_0165204d3c", unique: true
    t.index ["alert_rule_id"], name: "index_alert_rule_channels_on_alert_rule_id"
    t.index ["notification_channel_id"], name: "index_alert_rule_channels_on_notification_channel_id"
  end

  create_table "alert_rules", force: :cascade do |t|
    t.string "condition", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.integer "for_minutes", default: 2, null: false
    t.text "last_error"
    t.datetime "last_error_at"
    t.datetime "last_evaluated_at"
    t.integer "managed_app_id"
    t.string "name", null: false
    t.json "params", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["managed_app_id"], name: "index_alert_rules_on_managed_app_id"
  end

  create_table "app_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "managed_app_id", null: false
    t.integer "user_id", null: false
    t.index ["managed_app_id"], name: "index_app_memberships_on_managed_app_id"
    t.index ["user_id", "managed_app_id"], name: "index_app_memberships_on_user_id_and_managed_app_id", unique: true
    t.index ["user_id"], name: "index_app_memberships_on_user_id"
  end

  create_table "audit_logs", force: :cascade do |t|
    t.string "action_name", null: false
    t.text "command"
    t.datetime "created_at", null: false
    t.string "detail"
    t.text "detail_args"
    t.string "detail_key"
    t.integer "duration_ms"
    t.datetime "finished_at"
    t.text "hosts"
    t.integer "managed_app_id"
    t.text "output_digest"
    t.string "result", default: "pending", null: false
    t.string "target"
    t.integer "target_user_id"
    t.string "target_version"
    t.integer "user_id", null: false
    t.index ["created_at"], name: "index_audit_logs_on_created_at"
    t.index ["managed_app_id", "created_at"], name: "index_audit_logs_on_managed_app_id_and_created_at"
    t.index ["managed_app_id"], name: "index_audit_logs_on_managed_app_id"
    t.index ["target_user_id"], name: "index_audit_logs_on_target_user_id"
    t.index ["user_id"], name: "index_audit_logs_on_user_id"
  end

  create_table "container_metrics", force: :cascade do |t|
    t.bigint "block_read_bytes"
    t.bigint "block_write_bytes"
    t.string "container_name", null: false
    t.float "cpu_percent"
    t.string "host", null: false
    t.string "kind", null: false
    t.integer "managed_app_id", null: false
    t.bigint "mem_bytes"
    t.bigint "mem_limit_bytes"
    t.float "mem_percent"
    t.bigint "net_rx_bytes"
    t.bigint "net_tx_bytes"
    t.integer "pids"
    t.datetime "sampled_at", null: false
    t.string "source", null: false
    t.string "version"
    t.index ["managed_app_id", "host", "container_name", "sampled_at"], name: "index_container_metrics_unique_sample", unique: true
    t.index ["managed_app_id", "sampled_at"], name: "index_container_metrics_on_managed_app_id_and_sampled_at"
    t.index ["sampled_at"], name: "index_container_metrics_on_sampled_at"
  end

  create_table "credentials", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "fingerprint"
    t.string "kind", default: "ssh_key", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.index ["name"], name: "index_credentials_on_name", unique: true
  end

  create_table "deploy_events", force: :cascade do |t|
    t.integer "audit_log_id"
    t.string "command"
    t.datetime "created_at", null: false
    t.string "destination"
    t.datetime "failed_at"
    t.integer "managed_app_id", null: false
    t.datetime "observed_at"
    t.string "performer"
    t.datetime "recorded_at"
    t.string "source", default: "hook", null: false
    t.datetime "started_at"
    t.datetime "succeeded_at"
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["audit_log_id"], name: "index_deploy_events_on_audit_log_id"
    t.index ["managed_app_id", "created_at"], name: "index_deploy_events_on_managed_app_id_and_created_at"
    t.index ["managed_app_id", "version", "succeeded_at"], name: "idx_on_managed_app_id_version_succeeded_at_fe5db543c5"
    t.index ["managed_app_id"], name: "index_deploy_events_on_managed_app_id"
  end

  create_table "git_connections", force: :cascade do |t|
    t.string "api_url", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "provider", null: false
    t.text "token", null: false
    t.datetime "updated_at", null: false
    t.string "web_url", null: false
    t.index ["name"], name: "index_git_connections_on_name", unique: true
  end

  create_table "host_metrics", force: :cascade do |t|
    t.bigint "cpu_idle_jiffies"
    t.float "cpu_percent"
    t.bigint "cpu_total_jiffies"
    t.integer "cpus"
    t.bigint "disk_total_bytes"
    t.bigint "disk_used_bytes"
    t.string "host", null: false
    t.float "load1"
    t.float "load15"
    t.float "load5"
    t.integer "managed_app_id", null: false
    t.bigint "mem_available_bytes"
    t.bigint "mem_total_bytes"
    t.datetime "sampled_at", null: false
    t.bigint "swap_free_bytes"
    t.bigint "swap_total_bytes"
    t.index ["managed_app_id", "host", "sampled_at"], name: "index_host_metrics_on_managed_app_id_and_host_and_sampled_at", unique: true
    t.index ["managed_app_id"], name: "index_host_metrics_on_managed_app_id"
    t.index ["sampled_at"], name: "index_host_metrics_on_sampled_at"
  end

  create_table "instance_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "license_text"
    t.datetime "updated_at", null: false
  end

  create_table "managed_apps", force: :cascade do |t|
    t.text "config_yaml", null: false
    t.datetime "created_at", null: false
    t.datetime "deactivated_at"
    t.string "destination"
    t.text "destination_config_yaml"
    t.datetime "first_poll_error_at"
    t.string "git_branch"
    t.integer "git_connection_id"
    t.string "hook_token_digest"
    t.text "kamal_hooks"
    t.text "kamal_secrets"
    t.datetime "last_converged_at"
    t.string "last_converged_version"
    t.text "last_hook_rejection"
    t.datetime "last_hook_rejection_at"
    t.text "last_poll_error"
    t.datetime "last_poll_error_at"
    t.string "name", null: false
    t.integer "registry_credential_id"
    t.string "repository"
    t.integer "ssh_credential_id"
    t.datetime "updated_at", null: false
    t.string "version_format", default: "sha", null: false
    t.index ["git_connection_id"], name: "index_managed_apps_on_git_connection_id"
    t.index ["hook_token_digest"], name: "index_managed_apps_on_hook_token_digest", unique: true
    t.index ["name"], name: "index_managed_apps_on_name", unique: true
    t.index ["registry_credential_id"], name: "index_managed_apps_on_registry_credential_id"
    t.index ["ssh_credential_id"], name: "index_managed_apps_on_ssh_credential_id"
  end

  create_table "notification_channels", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "kind", null: false
    t.datetime "last_delivered_at"
    t.text "last_error"
    t.datetime "last_error_at"
    t.string "name", null: false
    t.text "secret"
    t.text "target", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_notification_channels_on_name", unique: true
  end

  create_table "observations", force: :cascade do |t|
    t.string "container_name"
    t.datetime "created_at", null: false
    t.string "docker_status"
    t.string "error"
    t.string "health"
    t.string "host", null: false
    t.integer "managed_app_id", null: false
    t.datetime "observed_at", null: false
    t.boolean "reachable", default: true, null: false
    t.string "role"
    t.string "version"
    t.index ["managed_app_id", "host", "observed_at"], name: "index_observations_on_managed_app_id_and_host_and_observed_at"
    t.index ["managed_app_id", "observed_at"], name: "index_observations_on_managed_app_id_and_observed_at"
    t.index ["managed_app_id"], name: "index_observations_on_managed_app_id"
  end

  create_table "proxy_targets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "error"
    t.string "host", null: false
    t.integer "managed_app_id", null: false
    t.datetime "observed_at", null: false
    t.text "raw"
    t.boolean "reachable", default: true, null: false
    t.string "service_name"
    t.string "state"
    t.string "target"
    t.index ["managed_app_id", "host", "observed_at"], name: "index_proxy_targets_on_managed_app_id_and_host_and_observed_at"
    t.index ["managed_app_id", "observed_at"], name: "index_proxy_targets_on_managed_app_id_and_observed_at"
    t.index ["managed_app_id"], name: "index_proxy_targets_on_managed_app_id"
  end

  create_table "registry_credentials", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "server"
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.index ["name"], name: "index_registry_credentials_on_name", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deactivated_at"
    t.string "email_address", null: false
    t.string "locale"
    t.string "nickname"
    t.string "password_digest", null: false
    t.string "role", default: "ops", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "alert_events", "alert_rules"
  add_foreign_key "alert_events", "managed_apps"
  add_foreign_key "alert_rule_channels", "alert_rules"
  add_foreign_key "alert_rule_channels", "notification_channels"
  add_foreign_key "alert_rules", "managed_apps"
  add_foreign_key "app_memberships", "managed_apps"
  add_foreign_key "app_memberships", "users"
  add_foreign_key "audit_logs", "managed_apps"
  add_foreign_key "audit_logs", "users"
  add_foreign_key "audit_logs", "users", column: "target_user_id"
  add_foreign_key "container_metrics", "managed_apps"
  add_foreign_key "deploy_events", "audit_logs"
  add_foreign_key "deploy_events", "managed_apps"
  add_foreign_key "host_metrics", "managed_apps"
  add_foreign_key "managed_apps", "credentials", column: "ssh_credential_id"
  add_foreign_key "managed_apps", "git_connections"
  add_foreign_key "managed_apps", "registry_credentials"
  add_foreign_key "observations", "managed_apps"
  add_foreign_key "proxy_targets", "managed_apps"
  add_foreign_key "sessions", "users"
end
