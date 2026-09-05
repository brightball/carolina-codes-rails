class ApplicationController < ActionController::API
  after_action :polyglot_headers

  private

  def polyglot_headers
    response.set_header("X-Polyglot-Language", Catalog::LANGUAGE)
    response.set_header("X-Polyglot-Framework", Catalog::FRAMEWORK)
  end
end
