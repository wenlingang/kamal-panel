module GitProviders
  # One commit as both providers describe it, normalized. author_avatar may be nil (GitHub: the
  # email isn't linked to an account; GitLab: no avatar for that email).
  Commit = Data.define(:sha, :title, :message, :author_name, :author_avatar, :committed_at, :web_url)
end
