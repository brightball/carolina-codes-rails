Rails.application.routes.draw do
  root "identity#show"
  get "/health", to: "health#show"

  get "/v1/years", to: "years#index"

  get "/v1/speakers", to: "speakers#index"
  get "/v1/speakers/:year/:slug", to: "speakers#year_show", constraints: { year: /\d{4}/ }
  get "/v1/speakers/:slug", to: "speakers#show"

  get "/v1/sponsors", to: "sponsors#index"
  get "/v1/sponsors/:year/:slug", to: "sponsors#year_show", constraints: { year: /\d{4}/ }
  get "/v1/sponsors/:slug", to: "sponsors#show"
end
