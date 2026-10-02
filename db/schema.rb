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

ActiveRecord::Schema[8.1].define(version: 2026_09_13_140000) do
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
    t.integer "target_user_id"
    t.string "target_version"
    t.integer "user_id", null: false
    t.index ["created_at"], name: "index_audit_logs_on_created_at"
    t.index ["managed_app_id", "created_at"], name: "index_audit_logs_on_managed_app_id_and_created_at"
    t.index ["managed_app_id"], name: "index_audit_logs_on_managed_app_id"
    t.index ["target_user_id"], name: "index_audit_logs_on_target_user_id"
    t.index ["user_id"], name: "index_audit_logs_on_user_id"
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
    t.string "command"
    t.datetime "created_at", null: false
    t.string "destination"
    t.integer "managed_app_id", null: false
    t.datetime "observed_at"
    t.string "performer"
    t.datetime "recorded_at"
    t.string "source", default: "hook", null: false
    t.datetime "started_at"
    t.datetime "succeeded_at"
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["managed_app_id", "created_at"], name: "index_deploy_events_on_managed_app_id_and_created_at"
    t.index ["managed_app_id", "version", "succeeded_at"], name: "idx_on_managed_app_id_version_succeeded_at_fe5db543c5"
    t.index ["managed_app_id"], name: "index_deploy_events_on_managed_app_id"
  end

  create_table "managed_apps", force: :cascade do |t|
    t.text "config_yaml", null: false
    t.datetime "created_at", null: false
    t.datetime "deactivated_at"
    t.string "destination"
    t.text "destination_config_yaml"
    t.datetime "first_poll_error_at"
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
    t.integer "ssh_credential_id"
    t.datetime "updated_at", null: false
    t.index ["hook_token_digest"], name: "index_managed_apps_on_hook_token_digest", unique: true
    t.index ["name"], name: "index_managed_apps_on_name", unique: true
    t.index ["registry_credential_id"], name: "index_managed_apps_on_registry_credential_id"
    t.index ["ssh_credential_id"], name: "index_managed_apps_on_ssh_credential_id"
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

  add_foreign_key "app_memberships", "managed_apps"
  add_foreign_key "app_memberships", "users"
  add_foreign_key "audit_logs", "managed_apps"
  add_foreign_key "audit_logs", "users"
  add_foreign_key "audit_logs", "users", column: "target_user_id"
  add_foreign_key "deploy_events", "managed_apps"
  add_foreign_key "managed_apps", "credentials", column: "ssh_credential_id"
  add_foreign_key "managed_apps", "registry_credentials"
  add_foreign_key "observations", "managed_apps"
  add_foreign_key "proxy_targets", "managed_apps"
  add_foreign_key "sessions", "users"
end
