# Hourly: the certificate of every HTTPS domain of every active app (proxy.ssl in deploy.yml), for
# the cert_expiring alert rule and the app page. Certificates change rarely; an hour is plenty.
class CheckCertificatesJob < ApplicationJob
  queue_as :collect

  limits_concurrency to: 1, key: "check_certificates", duration: 30.minutes, on_conflict: :discard

  def perform(now: Time.current)
    hosts = ManagedApp.active.where(last_poll_error: nil).flat_map do |app|
      app.parsed_config.domains.select { |domain| domain[:ssl] }.map { |domain| domain[:host] }
    rescue Kamal::ConfigParser::ParseError
      []
    end.uniq

    OutboundHttp.parallel_map(hosts, threads: 4) { |host| [ host, CertificateProbe.call(host) ] }.each do |host, result|
      next unless host.is_a?(String)

      check = CertificateCheck.find_or_initialize_by(host:)
      if result.error
        # Keep the last expiry we did read: a blip in reaching the site doesn't erase what we know.
        check.update!(error: result.error, checked_at: now)
      else
        check.update!(not_after: result.not_after, issuer: result.issuer, error: nil, checked_at: now)
      end
    end

    CertificateCheck.where.not(host: hosts).delete_all
  end
end
