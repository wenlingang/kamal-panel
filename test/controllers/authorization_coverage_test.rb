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
    "RegistryCredentialsController" => %w[new create edit update destroy]
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
