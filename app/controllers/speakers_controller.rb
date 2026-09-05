class SpeakersController < ApplicationController
  def index
    render json: { data: Catalog.speakers(params[:year]) }
  end

  def show
    speaker = Catalog.speaker(params[:slug])
    if speaker
      render json: { data: speaker }
    else
      render json: { error: "not_found" }, status: :not_found
    end
  end

  def year_show
    speaker = Catalog.speaker_for_year(params[:year], params[:slug])
    if speaker.nil? || speaker == :missing_year
      render json: { error: "not_found" }, status: :not_found
    else
      render json: { data: speaker }
    end
  end
end
