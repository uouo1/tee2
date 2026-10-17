# frozen_string_literal: true

module Api
  # GET /api/alerts — every saved search re-run above its watermark
  # (get_alerts in argos/api.py). mark_seen=1 acknowledges what it returns.
  class AlertsController < BaseController
    def index
      render json: { alerts: Analytics.check_alerts(mark_seen: bool_param(:mark_seen, false)) }
    end
  end
end
