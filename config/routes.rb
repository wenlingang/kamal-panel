Rails.application.routes.draw do
  resource :session
  # 改自己的界面语言。刻意【不】放在 resources :users 下面：那一组是 admin
  # 独占的，而换语言人人都得能做（见 LocalesControllerTest 顶部的注释）。
  resource :locale, only: [ :update ]
  resources :passwords, param: :token
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  resources :managed_apps, path: "apps", only: [ :index, :new, :create, :show, :edit, :update ] do
    resources :actions, only: [ :create, :show ]
    resource :hook_token, only: [ :create ]
    # 手动触发一次采集。是【读】动作：不取部署锁、不写审计、三档角色都能用
    # ——它只是让一次本来就会自动发生的采集提前。
    resources :refreshes, only: [ :create ]
    # 停用而不是删除：audit_logs 有一条指向 managed_apps 的外键，而审计行是
    # 设计上不可删除的。与"用户只停用不删除"同一个形状。
    post :deactivate, on: :member
    post :reactivate, on: :member
  end
  # hook 上报入口。客户端是 curl，不是浏览器——控制器因此继承
  # ActionController::API（无 CSRF、无 cookie、无 allow_browser）。
  namespace :api do
    resources :deploys, only: [ :create ]
  end
  resources :audit_logs, only: [ :index ]

  # 人员管理。没有 destroy：用户只能停用不能删除（audit_logs.user_id 带外键，
  # 而审计不可删除）。
  resources :users, only: [ :index, :new, :create, :edit, :update ] do
    post :deactivate, on: :member
    post :reactivate, on: :member
  end
  # 凭据只有 admin 能管（设计 12）。没有 show：凭据是只写不读的，没有"看一眼
  # 内容"这回事。
  resources :credentials, only: [ :index, :new, :create, :edit, :update, :destroy ]
  resources :registry_credentials, only: [ :new, :create, :edit, :update, :destroy ],
            path: "credentials/registry"

  resource :overview, only: [ :show ]

  # Defines the root path route ("/")
  root "overviews#show"
end
