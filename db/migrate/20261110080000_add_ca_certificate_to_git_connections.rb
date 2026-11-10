# Self-hosted Git platforms often sit behind a certificate from a company CA (or a self-signed one).
# The PEM is trusted for this connection only, on top of the system store.
class AddCaCertificateToGitConnections < ActiveRecord::Migration[8.1]
  def change
    add_column :git_connections, :ca_certificate, :text
  end
end
