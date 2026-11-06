module Metrics
  # A time range of the metrics tab (?range=), and the bucket its series are averaged into so a
  # chart never has more than a few hundred points per line, whatever the range.
  class TimeRange
    # key => [span, bucket seconds]: 60, 180, 288 and 336 points.
    OPTIONS = {
      "1h" => [ 1.hour, 60 ],
      "6h" => [ 6.hours, 120 ],
      "24h" => [ 24.hours, 300 ],
      "7d" => [ 7.days, 1800 ]
    }.freeze
    DEFAULT = "1h".freeze

    attr_reader :key, :span, :bucket_seconds, :to

    def self.keys = OPTIONS.keys

    def initialize(key, now: Time.current)
      @key = OPTIONS.key?(key.to_s) ? key.to_s : DEFAULT
      @span, @bucket_seconds = OPTIONS.fetch(@key)
      @to = now
    end

    def from = to - span

    # Where a bucket starts, from the integer the SQL groups by.
    def bucket_time(bucket) = Time.zone.at(bucket.to_i * bucket_seconds)

    # SQLite: whole seconds since the epoch divided into buckets. strftime('%s') reads Rails'
    # "YYYY-MM-DD HH:MM:SS[.ffffff]" (UTC) column format directly.
    def bucket_sql(column = "sampled_at")
      "(CAST(strftime('%s', #{column}) AS INTEGER) / #{Integer(bucket_seconds)})"
    end

    # Points further apart than this are drawn as a gap, not joined by a line. Never tighter than
    # a few missed collection rounds: with 1–2 minute buckets, one slow SSH round (or a sparser
    # sample history) would otherwise shred every line into dashes, which reads as an outage.
    MIN_GAP = 6.minutes.to_i

    def gap_seconds = [ bucket_seconds * 2.5, MIN_GAP ].max
  end
end
