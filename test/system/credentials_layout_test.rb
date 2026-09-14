require "application_system_test_case"

# button_to 生成的是 <form>，块级元素——和旁边的 <a> 放进同一个单元格，
# 它会自己掉到下一行去，「替换 / 删除」就错开成上下两行。这一条只在
# 真实浏览器里量得出来：HTML 结构是对的，错的是排版。
class CredentialsLayoutTest < ApplicationSystemTestCase
  setup do
    @admin = User.create!(email_address: "layout@example.com",
                          password: "secret123456", role: "admin")
    Credential.create!(kind: "ssh_key", value: FakeHost.private_key, name: "生产集群")
    RegistryCredential.create!(name: "docker hub", server: "registry-1.docker.io", value: "p")
  end

  # 两个控件的可视中线之差。用中线而不是 top：链接和按钮本来就不一样高，
  # 要求 top 相等等于要求它们高度相同，那是过度约束。
  def action_centers(table_index)
    page.evaluate_script(<<~JS)
      (() => {
        const cell = document.querySelectorAll('table')[#{table_index}]
                             .querySelector('tbody tr td:last-child');
        return Array.from(cell.querySelectorAll('a, form'))
                    .map(el => { const r = el.getBoundingClientRect();
                                 return r.top + r.height / 2; });
      })()
    JS
  end

  test "凭据表里的「替换」和「删除」排在同一行" do
    sign_in_as @admin
    visit credentials_path

    [ 0, 1 ].each do |table_index|
      centers = action_centers(table_index)
      assert_equal 2, centers.size, "第 #{table_index} 个表格应该同时有「替换」和「删除」"
      assert_in_delta centers.first, centers.last, 4,
                      "第 #{table_index} 个表格的「替换」和「删除」没有排在同一行"
    end
  end
end
