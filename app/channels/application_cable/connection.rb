module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      set_current_user || reject_unauthorized_connection
    end

    private
      # 这里重复了 Authentication#find_session_by_cookie 里的停用判断，是刻意的。
      def set_current_user
        session = Session.find_by(id: cookies.signed[:session_id])
        return if session.nil? || session.user.deactivated?

        self.current_user = session.user
      end
  end
end
