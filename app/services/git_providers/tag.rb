module GitProviders
  # commit is filled in when the provider's tag listing already carries it (GitLab); otherwise it
  # is nil and Base#commit_for_tag fetches it.
  Tag = Data.define(:name, :sha, :commit)
end
