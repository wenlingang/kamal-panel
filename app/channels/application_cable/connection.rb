module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      set_current_user || reject_unauthorized_connection
    end

    private
      # 这里重复了 Authentication#find_session_by_cookie 里的停用判断，是刻意的。
      # 停用会顺手销毁该用户的全部 session，所以今天这条分支走不到；但 Cable 走的
      # 是自己那条连接握手，不经过 before_action，"停用的人不该拿到任何东西"这句
      # 不变式在这里必须自己再说一遍——否则哪天停用改成不销毁 session，一条已经
      # 建立的 socket 会继续收广播，而没有任何测试或读者会注意到这个缺口。
      def set_current_user
        session = Session.find_by(id: cookies.signed[:session_id])
        return if session.nil? || session.user.deactivated?

        self.current_user = session.user
      end
  end
end
