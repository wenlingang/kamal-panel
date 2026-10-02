module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      set_current_user || reject_unauthorized_connection
    end

    private
      # Repeating the deactivation check from Authentication#find_session_by_cookie here is
      # deliberate.
      def set_current_user
        session = Session.find_by(id: cookies.signed[:session_id])
        return if session.nil? || session.user.deactivated?

        self.current_user = session.user
      end
  end
end
