class CreateBackups < ActiveRecord::Migration[8.1]
  def change
    # Where dumps go: any S3-compatible object storage (AWS S3, Cloudflare R2, MinIO, Aliyun OSS...).
    create_table :backup_destinations do |t|
      t.string :name, null: false
      t.string :endpoint, null: false
      t.string :region, null: false, default: "us-east-1"
      t.string :bucket, null: false
      t.string :prefix
      t.boolean :path_style, null: false, default: true
      t.string :access_key_id, null: false
      t.text :secret_access_key, null: false
      t.datetime :last_checked_at
      t.text :last_check_error
      t.timestamps
    end
    add_index :backup_destinations, :name, unique: true

    # One accessory of one app, dumped every every_hours and kept `keep` copies deep.
    create_table :backup_plans do |t|
      t.references :managed_app, null: false, foreign_key: true
      t.references :backup_destination, null: false, foreign_key: true
      t.string :accessory, null: false
      t.string :engine, null: false
      t.string :database
      t.integer :every_hours, null: false, default: 24
      t.integer :keep, null: false, default: 7
      t.boolean :enabled, null: false, default: true
      t.datetime :next_run_at
      t.timestamps
    end
    add_index :backup_plans, [ :managed_app_id, :accessory ], unique: true

    create_table :backup_runs do |t|
      t.references :backup_plan, null: false, foreign_key: true
      t.references :managed_app, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.string :state, null: false, default: "running"
      t.string :object_key
      t.bigint :size_bytes
      t.text :error
      t.text :diagnosis
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.datetime :pruned_at
      t.timestamps
    end
    add_index :backup_runs, [ :backup_plan_id, :started_at ]
    add_index :backup_runs, [ :managed_app_id, :finished_at ]
  end
end
