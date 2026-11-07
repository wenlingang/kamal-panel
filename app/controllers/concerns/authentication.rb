module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    # a person holding a cookie stays valid until the cookie expires. Asking on every request makes
    # deactivation take effect immediately.
    def find_session_by_cookie
      return nil unless cookies.signed[:session_id]

      Session.usable_by_id(cookies.signed[:session_id])
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.url
      redirect_to new_session_path
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || root_url
    end

    # remember: false gives a browser-session cookie (gone when the browser closes); true keeps it
    # for Session::REMEMBERED_FOR. Either way the session row carries its own expires_at, which is
    # what actually decides: a cookie can outlive its intent (session restore, a copied cookie).
    def start_new_session_for(user, remember: false)
      expires_at = Session.lifetime(remember:).from_now
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip, expires_at:).tap do |session|
        Current.session = session
        cookie = { value: session.id, httponly: true, same_site: :lax }
        cookie[:expires] = expires_at if remember
        cookies.signed[:session_id] = cookie
      end
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(:session_id)
    end
end
