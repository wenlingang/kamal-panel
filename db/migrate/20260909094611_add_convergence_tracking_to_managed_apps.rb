class AddConvergenceTrackingToManagedApps < ActiveRecord::Migration[8.1]
  def change
    # nil means "no baseline established yet": the first convergence only writes these two columns
    # and produces no event. An app that has long been running some version and has just been
    # onboarded to the panel was not "deployed today".
    add_column :managed_apps, :last_converged_version, :string
    # Stores the observation moment (the earliest observed_at among that batch of running
    # observations), not Time.current; the same reason as the Reconciler backfilling observed_at
    # with observation time.
    add_column :managed_apps, :last_converged_at, :datetime
  end
end
