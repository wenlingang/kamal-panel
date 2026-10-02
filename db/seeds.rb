# This file should ensure the existence of records required to run the application in every
# environment (production, development, test). The code here should be idempotent so that it can be
# executed at any point in every environment. The data can then be loaded with the bin/rails db:seed
# command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# The first admin is injected via env vars, so there is no such thing as a "default password".
if (email = ENV["KAMAL_PANEL_ADMIN_EMAIL"]).present?
  password = ENV.fetch("KAMAL_PANEL_ADMIN_PASSWORD")
  User.find_or_create_by!(email_address: email) do |user|
    user.password = password
    user.role = "admin"
  end
  puts "已创建 admin: #{email}"
end
