# Alert rules (spec 8): everyone signed in reads the list, admin adds, edits and deletes. Changes
# are audited like the other site-wide settings.
class AlertRulesController < ApplicationController
  authorize :manage, on: AlertRule, only: %i[ new create edit update destroy ]

  before_action :set_rule, only: %i[ edit update destroy ]
  before_action :load_choices, only: %i[ new create edit update ]

  def index
    @rules = AlertRule.includes(:managed_app, :notification_channels).order(:name)
    @firing_counts = AlertEvent.firing.group(:alert_rule_id).count
  end

  def new
    @rule = AlertRule.new(condition: "unhealthy", for_minutes: 2, enabled: true)
  end

  def create
    @rule = AlertRule.new(rule_params)

    if @rule.save
      AuditLog.record_access!(user: Current.user, action_name: "alert_rule.create", detail: @rule.name,
                              managed_app_id: @rule.managed_app_id)
      redirect_to alert_rules_path, notice: t("flash.alert_rule.added", name: @rule.name)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @rule.update(rule_params)
      AuditLog.record_access!(user: Current.user, action_name: "alert_rule.update", detail: @rule.name,
                              managed_app_id: @rule.managed_app_id)
      redirect_to alert_rules_path, notice: t("flash.alert_rule.updated", name: @rule.name)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Takes its events with it: they only mean something next to the rule that raised them.
  def destroy
    name = @rule.name
    app_id = @rule.managed_app_id
    @rule.destroy!
    AuditLog.record_access!(user: Current.user, action_name: "alert_rule.delete", detail: name, managed_app_id: app_id)
    redirect_to alert_rules_path, notice: t("flash.alert_rule.deleted", name: name)
  end

  private
    def set_rule = @rule = AlertRule.find(params[:id])

    def load_choices
      @apps = ManagedApp.active.order(:name)
      @channels = NotificationChannel.order(:name)
    end

    # The channel ids are checked against existing channels by the association itself; an unknown
    # id raises RecordNotFound (404) rather than being dropped silently.
    def rule_params
      permitted = params.expect(alert_rule: [ :name, :managed_app_id, :condition, :for_minutes, :enabled,
                                              :keyword, :window_minutes, :threshold, :log_source, :metric_threshold,
                                              { notification_channel_ids: [] } ])
      permitted[:notification_channel_ids] = Array(permitted[:notification_channel_ids]).compact_blank
      permitted[:managed_app_id] = permitted[:managed_app_id].presence
      permitted
    end
end
