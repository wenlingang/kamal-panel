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

  resource :overview, only: [ :show ]

  # Defines the root path route ("/")
  root "overviews#show"
end
