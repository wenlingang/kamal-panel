module Alerting
  # One log-keyword scan of one app for one rule (spec 8): count the keyword over the rule's window
  # with LogQuery, then feed the verdict to the StateMachine like any state condition.
  #
  # Hosts that can't be read are not "zero hits". When none could be read, nothing changes and the
  # rule records why (shown on the rules page); when some could, a count at or over the threshold
  # still counts, but a count under it can't clear the alert — the missing hosts might hold the rest.
  class LogScan
    LINES = 1000

    def self.call(...) = new(...).call

    def initialize(rule, app, now: Time.current, query: nil)
      @rule = rule
      @app = app
      @now = now
      @query = query
    end

    # Returns true when an event changed (see StateMachine#apply).
    def call
      result = (query || LogQuery.new(app, source: rule.log_source.presence || "app", since: now - rule.window,
                                           grep: rule.keyword, lines: LINES, now:)).call
      check = verdict(result)
      record_errors(result)
      StateMachine.apply(rule, app, check, now:)
    rescue LogQuery::InvalidQuery, Kamal::ConfigParser::ParseError => e
      rule.record_error!("#{app.name}: #{e.message}")
      false
    end

    def verdict(result)
      return nil if all_hosts_failed?(result)

      count = result.entries.size
      threshold = rule.threshold.to_i
      if count >= threshold
        Check.holds("log_keyword", keyword: rule.keyword, count:, threshold:, window: rule.window_minutes.to_i)
      elsif result.errors.any?
        nil
      else
        Check.clear
      end
    end

    private
      attr_reader :rule, :app, :now, :query

      def all_hosts_failed?(result)
        result.errors.any? && (result.hosts - result.errors.map(&:host)).empty?
      end

      def record_errors(result)
        if result.errors.empty?
          rule.clear_error!
        else
          details = result.errors.map { |error| [ error.host, error.kind, error.detail ].compact.join(" ") }
          rule.record_error!("#{app.name}: #{details.join('; ')}")
        end
      end
  end
end
