require "test_helper"

# Forgetting to attach one authorization filter is the classic accident of this kind of refactor,
# and it [won't turn any other test red]
# -- the action works as usual, just for everyone. This test is the only thing that can catch it in CI.
#
# The list here is written by hand and deliberately hard-coded: it expresses the intent that "these
# actions must be authorized", not a fact inferred back from the code. A test inferred from the code
# is forever true.
class AuthorizationCoverageTest < ActiveSupport::TestCase
  DECLARATIVE = {
    "ManagedAppsController" => %w[new create],
    "UsersController" => %w[index new create edit update deactivate reactivate],
    "CredentialsController" => %w[index new create edit update destroy],
    "RegistryCredentialsController" => %w[new create edit update destroy],
    "GitConnectionsController" => %w[index new create edit update destroy check],
    "NotificationChannelsController" => %w[index new create edit update destroy test_delivery],
    # index is not here on purpose: everyone signed in reads the rules (AlertsController too).
    "AlertRulesController" => %w[new create edit update destroy]
  }.freeze

  # Actions whose permission depends on the app in the URL can't be declared with a class macro
  # (before_action can't get at the record params points to); they check inside the method body.
  # They are listed here, and a source assertion below confirms that check is still there -- better
  # than "checking nothing", more honest than pretending they are declarative too.
  # RefreshesController#create is in none of the tables above, deliberately: manual refresh is a
  # read action
  # -- it takes no deploy lock, writes no audit, changes no live state, and only moves up a collection that would
  # have happened automatically anyway (design 11 §3.2, open to all three roles). Don't "fix" it by
  # adding it in.
  # DeploysController (index, new) is not listed either: like the overview and each app's history
  # it is readable by everyone signed in, and new only lists the apps the person may deploy; the
  # deploy itself goes through AppDeploysController.
  INLINE = {
    "app/controllers/actions_controller.rb"     => [
      "ManagedAppPolicy.new(Current.user, app).run?",
      # show renders the action's full output, so it must use the same check as launching an action.
      "ManagedAppPolicy.new(Current.user, @managed_app).run?(action_class)"
    ],
    "app/controllers/managed_apps_controller.rb" => [
      "require_permission!(:act, @managed_app)",
      "require_permission!(:deactivate, @managed_app)"
    ],
    "app/controllers/hook_tokens_controller.rb" => [
      "require_permission!(:regenerate_hook_token, app)"
    ],
    # versions / new / create: deploying is act? (spec 9), the version list and confirm page too.
    "app/controllers/app_deploys_controller.rb" => [
      "require_permission!(:act, @managed_app)"
    ],
    # index (with an app chosen) and results: reading logs is view_logs? (spec 9). index without an
    # app only lists apps already filtered by the same policy.
    "app/controllers/logs_controller.rb" => [
      "require_permission!(:view_logs, @managed_app)",
      "policy_for(app).view_logs?"
    ]
  }.freeze

  test "no declaratively authorized controller action is missing a rule" do
    DECLARATIVE.each do |controller_name, actions|
      controller = controller_name.constantize
      covered = controller.authorization_rules.flat_map { |rule| rule[:only] }.map(&:to_s)

      actions.each do |action|
        assert_includes covered, action,
          "#{controller_name}##{action} declares no authorization rule -- it is currently open to any signed-in user"
      end
    end
  end

  test "the inline authorization check is still present in inline-authorized controllers" do
    INLINE.each do |path, needles|
      source = Rails.root.join(path).read

      needles.each do |needle|
        assert_includes source, needle,
          "the authorization check in #{path} is gone -- this action is currently open to any signed-in user"
      end
    end
  end
end
