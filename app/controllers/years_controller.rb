class YearsController < ApplicationController
  def index
    render json: { data: Catalog.years }
  end
end
