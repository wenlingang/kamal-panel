# What TLS certificate a domain served the last time CheckCertificatesJob looked: its expiry, or
# why it couldn't be read. One row per host, overwritten each check.
class CertificateCheck < ApplicationRecord
  validates :host, presence: true, uniqueness: true

  def days_left(now = Time.current) = not_after && ((not_after - now) / 1.day).floor
end
