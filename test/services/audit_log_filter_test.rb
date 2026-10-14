require "test_helper"

class AuditLogFilterTest < ActiveSupport::TestCase
  setup do
    @blog = ManagedApp.create!(name: "blog", config_yaml: file_fixture("simple_deploy.yml").read,
                               destination: "production")
    @shop = ManagedApp.create!(name: "shop", config_yaml: file_fixture("simple_deploy.yml").read,
                               destination: "production")
  end

  def log(app:, user: users(:two), result: "success")
    entry = AuditLog.start!(user:, managed_app: app, action_name: "restart", target_version: nil, hosts: [])
    entry.finish!(result:, command: "kamal app boot", output_digest: "", duration_ms: 1) unless result == "pending"
    entry
  end

  def page(**params) = AuditLogFilter.new(**params).page

  test "no filter returns everything, newest first" do
    first = log(app: @blog)
    second = log(app: @shop)

    assert_equal [ second, first ], page.entries
  end

  test "filters by app, actor and result together" do
    wanted = log(app: @blog, user: users(:one), result: "failure")
    log(app: @blog, user: users(:one), result: "success")
    log(app: @blog, user: users(:two), result: "failure")
    log(app: @shop, user: users(:one), result: "failure")

    assert_equal [ wanted ], page(app_id: @blog.id, user_id: users(:one).id, result: "failure").entries
  end

  test "the site-wide option keeps only entries that belong to no app" do
    site_wide = AuditLog.record_access!(user: users(:two), action_name: "user.create", target_user: users(:one))
    log(app: @blog)

    assert_equal [ site_wide ], page(app_id: AuditLogFilter::SITE_WIDE).entries
  end

  test "values from a hand-edited URL that match nothing are ignored, not turned into an empty page" do
    entry = log(app: @blog)

    filter = AuditLogFilter.new(app_id: "nope", user_id: "", result: "exploded")

    assert_not filter.active?
    assert_equal [ entry ], filter.page.entries
  end

  test "pages by id: the next page continues strictly before the last entry shown" do
    entries = Array.new(AuditLogFilter::PER_PAGE + 2) { log(app: @blog) }.reverse

    first_page = page
    assert_equal entries.first(AuditLogFilter::PER_PAGE), first_page.entries
    assert_equal entries[AuditLogFilter::PER_PAGE - 1].id, first_page.next_before

    second_page = page(before: first_page.next_before)
    assert_equal entries.last(2), second_page.entries
    assert_nil second_page.next_before
  end
end
