require "test_helper"

class CertificateCheckTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def certificate(not_after)
    key = OpenSSL::PKey::EC.generate("prime256v1")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/O=Let's Encrypt/CN=R11")
    cert.public_key = key
    cert.not_before = Time.current - 60.days
    cert.not_after = not_after
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    cert
  end

  setup do
    # simple_deploy.yml routes blog.example.com through kamal-proxy; turn its ssl on.
    yaml = file_fixture("simple_deploy.yml").read.sub("proxy:\n  host: blog.example.com", "proxy:\n  host: blog.example.com\n  ssl: true")
    @app = ManagedApp.create!(name: "blog", config_yaml: yaml, destination: "production")
  end

  teardown { CertificateProbe.connector = nil }

  test "reads the expiry of each HTTPS domain, keeps the last good read on an error" do
    expires = (Time.current + 10.days).change(usec: 0)
    CertificateProbe.connector = ->(_host, _port) { certificate(expires) }
    CheckCertificatesJob.perform_now

    check = CertificateCheck.find_by!(host: "blog.example.com")
    assert_equal expires, check.not_after
    assert_equal "Let's Encrypt R11", check.issuer

    CertificateProbe.connector = ->(_host, _port) { raise Errno::ECONNREFUSED }
    CheckCertificatesJob.perform_now
    assert_equal expires, check.reload.not_after
    assert_match "ECONNREFUSED", check.error
  end

  test "a cert_expiring rule fires inside its window and clears after renewal" do
    channel = NotificationChannel.create!(name: "hook", kind: "webhook", target: "https://hooks.example.com/x")
    rule = AlertRule.create!(name: "证书", condition: "cert_expiring", for_minutes: 0, days: 14, notification_channels: [ channel ])
    assert_equal({ "days" => 14 }, rule.params)

    CertificateCheck.create!(host: "blog.example.com", not_after: 5.days.from_now, checked_at: Time.current)
    Alerting::Evaluator.call
    event = AlertEvent.find_by!(alert_rule: rule)
    assert_predicate event, :firing?
    assert_includes event.message, "blog.example.com"

    CertificateCheck.update_all(not_after: 80.days.from_now)
    Alerting::Evaluator.call
    assert_predicate event.reload, :resolved?
  end
end
