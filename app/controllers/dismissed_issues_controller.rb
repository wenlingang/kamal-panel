# "Seen" on a needs-attention item. Only an item the person can see can be dismissed (the list is
# already narrowed to their apps, and settings items to admins), so the key is checked against it.
class DismissedIssuesController < ApplicationController
  def create
    item = AttentionItems.new(Current.user).find(params[:key].to_s)
    if item
      DismissedIssue.find_or_create_by!(issue_key: item.key, since: item.since) { |issue| issue.user = Current.user }
    end

    redirect_back_or_to root_path
  end
end
