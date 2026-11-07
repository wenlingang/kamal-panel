module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      set_current_user || reject_unauthorized_connection
    end

    private
      # The same check as Authentication#find_session_by_cookie (expired, deactivated), through
      # the one shared method so the two ways in can't drift apart.
      def set_current_user
        session = Session.usable_by_id(cookies.signed[:session_id])
        return if session.nil?

        self.current_user = session.user
      end
  end
end
