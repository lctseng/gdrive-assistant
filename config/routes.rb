# frozen_string_literal: true

require 'sidekiq/web'
Rails.application.routes.draw do
  devise_for :users
  # For details on the DSL available within this file, see http://guides.rubyonrails.org/routing.html
  namespace :api do
    resources :gdrive, controller: 'gdrive', only: [] do
      collection do
        post 'verify'
        get 'ping'
      end
      member do
        get 'verify_status'
      end
    end
  end

  authenticate :user do
    mount Sidekiq::Web => '/sidekiq'
  end
end
