require "shellwords"
require "zlib"

# One backup of one plan, start to finish: dump the database inside the accessory's container over
# SSH, gzip it on the way into a temp file, upload it, then drop the copies past the plan's `keep`.
#
# The dump runs with the credentials already in the container's environment (POSTGRES_USER,
# MYSQL_ROOT_PASSWORD...), the ones Kamal set from the app's secrets: the panel never needs the
# database password itself.
class BackupRunner
  DUMP_TIMEOUT = 1.hour.to_i

  def self.call(...) = new(...).call

  # session: anything with Collectors::SshSession#stream (tests pass a canned one).
  def initialize(plan, user: nil, now: Time.current, session: nil)
    @plan = plan
    @user = user
    @now = now
    @session = session
  end

  # Returns the BackupRun, finished either way.
  def call
    run = plan.backup_runs.create!(managed_app: plan.managed_app, user:, state: "running", started_at: now)

    Tempfile.create([ "backup", ".sql.gz" ], binmode: true) do |file|
      result = dump_into(file)
      next fail!(run, result[:stderr].presence || "exit status #{result[:status]}") unless result[:status].to_i.zero?
      next fail!(run, I18n.t("backups.runner.empty_dump")) if result[:bytes].zero?

      key = plan.backup_destination.key_for("#{plan.managed_app.name}/#{plan.accessory}/#{now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{run.id}.sql.gz")
      size = file.size
      File.open(file.path, "rb") do |io|
        plan.backup_destination.storage.put(key, io, size:, sha256: Digest::SHA256.file(file.path).hexdigest,
                                                     content_type: "application/gzip")
      end

      run.update!(state: "succeeded", object_key: key, size_bytes: size, finished_at: Time.current)
    end

    prune
    run
  rescue *Collectors::SshSession::CONNECTIVITY_ERRORS, ObjectStorage::Error, Kamal::ConfigParser::ParseError, Errno::ENOSPC => e
    fail!(run, "#{e.class}: #{e.message}")
  end

  # The shell command run on the host for this plan, exposed for the page that shows how to restore.
  def self.dump_command(plan)
    container = plan.accessory_config&.fetch(:container_name, nil) || "#{plan.managed_app.parsed_config.service}-#{plan.accessory}"
    "docker exec #{Shellwords.escape(container)} sh -c #{Shellwords.escape(inner_dump(plan))}"
  end

  # How to put a dump back, for the person reading the plan's page. Not run by the panel: restoring
  # overwrites live data, which is for someone to do deliberately.
  def self.restore_command(plan, file: "backup.sql.gz")
    container = plan.accessory_config&.fetch(:container_name, nil) || "#{plan.managed_app.parsed_config.service}-#{plan.accessory}"
    load = case plan.engine
    when "postgres"
             db = plan.database ? Shellwords.escape(plan.database) : '"${POSTGRES_DB:-$POSTGRES_USER}"'
             %(PGPASSWORD="$POSTGRES_PASSWORD" psql -U "${POSTGRES_USER:-postgres}" #{db})
    when "mysql"
             db = plan.database ? " #{Shellwords.escape(plan.database)}" : ""
             %(MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}" "$(command -v mysql || command -v mariadb)" -uroot#{db})
    end
    "gunzip -c #{Shellwords.escape(file)} | docker exec -i #{Shellwords.escape(container)} sh -c #{Shellwords.escape(load)}"
  end

  def self.inner_dump(plan)
    case plan.engine
    when "postgres"
      db = plan.database ? Shellwords.escape(plan.database) : '"${POSTGRES_DB:-${POSTGRES_USER:-postgres}}"'
      %(PGPASSWORD="$POSTGRES_PASSWORD" exec pg_dump -U "${POSTGRES_USER:-postgres}" --no-owner --no-privileges --clean --if-exists #{db})
    when "mysql"
      target = plan.database ? "--databases #{Shellwords.escape(plan.database)}" : "--all-databases"
      %(MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}" exec "$(command -v mysqldump || command -v mariadb-dump)" -uroot --single-transaction --routines --triggers --events #{target})
    else
      raise ArgumentError, "no dump for engine #{plan.engine.inspect}"
    end
  end

  private
    attr_reader :plan, :user, :now

    def session = @session ||= Collectors::SshSession.new(plan.managed_app, execution_timeout: DUMP_TIMEOUT)

    def dump_into(file)
      host = Array(plan.accessory_config&.fetch(:hosts, nil)).first
      raise Kamal::ConfigParser::ParseError, "accessory #{plan.accessory} is not in deploy.yml" if host.nil?

      gzip = Zlib::GzipWriter.new(file)
      bytes = 0
      result = session.stream(host, self.class.dump_command(plan), timeout: DUMP_TIMEOUT) do |chunk|
        bytes += chunk.bytesize
        gzip.write(chunk)
      end
      gzip.finish
      file.flush
      result.merge(bytes:)
    end

    def fail!(run, message)
      return nil if run.nil?

      run.update!(state: "failed", error: message.to_s.truncate(4000), diagnosis: FailureDiagnosis.call(message),
                  finished_at: Time.current)
      run
    end

    # Keeps the newest `keep` dumps that still exist; removes the objects of the rest. A delete that
    # fails is tried again after the next backup (the row stays unpruned).
    def prune
      plan.backup_runs.downloadable.order(started_at: :desc).offset(plan.keep).each do |old|
        plan.backup_destination.storage.delete(old.object_key)
        old.update!(pruned_at: Time.current)
      rescue ObjectStorage::Error => e
        Rails.logger.warn("[backup] could not remove #{old.object_key}: #{e.message}")
      end
    end
end
