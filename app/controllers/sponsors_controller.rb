class SponsorsController < ApplicationController
  def index
    render json: { data: Catalog.sponsors(params[:year]) }
  end

  def show
    sponsor = Catalog.sponsor(params[:slug])
    if sponsor
      render json: { data: sponsor }
    else
      render json: { error: "not_found" }, status: :not_found
    end
  end

  def year_show
    sponsor = Catalog.sponsor_for_year(params[:year], params[:slug])
    if sponsor
      render json: { data: sponsor }
    else
      render json: { error: "not_found" }, status: :not_found
    end
  end
end
