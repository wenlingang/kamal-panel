Rails.application.routes.draw do
  resource :session
  # Change your own UI language. Deliberately [not] under resources :users: that group is
  # admin-only, while changing language must be available to everyone (see the comment at the top of
  # LocalesControllerTest).
  resource :locale, only: [ :update ]
  resources :passwords, param: :token
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in
  # application.html.erb) get "manifest" => "rails/pwa#manifest", as: :pwa_manifest get
  # "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  resources :managed_apps, path: "apps", only: [ :index, :new, :create, :show, :edit, :update ] do
    resources :actions, only: [ :create, :show ]
    resource :hook_token, only: [ :create ]
    # Deploying a version CI already built: the version list (a frame on the app's deploy tab,
    # since it calls the Git platform and the registry), the confirm page, and the POST that runs
    # it through the closed action set.
    resource :deploy, only: [ :new, :create ], controller: "app_deploys" do
      get :versions
    end
    # Lock status and the action area attached to it. A separate route because reading the lock
    # means a real SSH, and running that synchronously in the detail page would drag the whole page
    # past 3 seconds (see the comment on that frame in show).
    resource :lock, only: [ :show ]
    # Manually trigger one collection. A [read] action: takes no deploy lock, writes no audit,
    # usable by all three roles (it only brings forward a collection that would happen automatically
    # anyway).
    resources :refreshes, only: [ :create ]
    # Deactivate rather than delete: audit_logs has a foreign key to managed_apps, and audit rows
    # are undeletable by design. Same shape as "users are only deactivated, never deleted".
    post :deactivate, on: :member
    post :reactivate, on: :member
  end
  # Entry point for hook reports. The client is curl, not a browser, so the controller inherits
  # ActionController::API (no CSRF, no cookies, no allow_browser).
  namespace :api do
    resources :deploys, only: [ :create ]
  end
  resources :audit_logs, only: [ :index ]
  # Recent deploys across apps; new picks the app to deploy.
  resources :deploys, only: [ :index, :new ]
  # Centralized logs: the page (form + empty frame) and the frame body, which does the SSH work and
  # also serves follow mode's increments. Conditions are query parameters so a URL can be shared.
  get "logs" => "logs#index", as: :logs
  get "logs/results" => "logs#results", as: :logs_results

  # Alerts (spec 8): the events page and the channels tab are readable by everyone signed in; rules
  # are readable by everyone and edited by admin. No show pages: a rule is its form, an event is
  # its row.
  resources :alerts, only: [ :index ]
  get "alerts/channels" => "alerts#channels", as: :alert_channels
  resources :alert_rules, only: [ :index, :new, :create, :edit, :update, :destroy ], path: "alerts/rules"
  # Settings → notifications: admin only, the target and secret are write-only like a Git token.
  # test_delivery sends a test message right away and reports the outcome.
  resources :notification_channels, only: [ :index, :new, :create, :edit, :update, :destroy ],
            path: "settings/notifications" do
    post :test_delivery, on: :member, path: "test"
  end

  # User management. No destroy: users can only be deactivated, not deleted (audit_logs.user_id has
  # a foreign key, and audits are undeletable).
  resources :users, only: [ :index, :new, :create, :edit, :update ] do
    post :deactivate, on: :member
    post :reactivate, on: :member
  end
  # Credentials are admin-only (design 12). No show: credentials are write-only, there is no such
  # thing as "taking a look at the contents".
  resources :credentials, only: [ :index, :new, :create, :edit, :update, :destroy ]
  resources :registry_credentials, only: [ :new, :create, :edit, :update, :destroy ],
            path: "credentials/registry"
  # No show for the same reason as credentials: the token is write-only. check calls the
  # provider with it and reports whether it works.
  resources :git_connections, only: [ :index, :new, :create, :edit, :update, :destroy ],
            path: "settings/git" do
    post :check, on: :member
  end

  resource :overview, only: [ :show ]

  # Defines the root path route ("/")
  root "overviews#show"
end
