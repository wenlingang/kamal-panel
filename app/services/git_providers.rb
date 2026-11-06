# Read-only clients for the Git platforms an app's source lives on (spec 6). The panel never writes
# back: no commit statuses, no deployments, no PR comments (spec 2 non-goals).
module GitProviders
  # What ci_status returns, from "stop" to "nothing to say".
  CI_STATUSES = %w[failure running pending success none].freeze
end
