class IdentityController < ApplicationController
  def show
    render json: Catalog.identity
  end
end
