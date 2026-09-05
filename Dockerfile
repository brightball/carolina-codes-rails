FROM ruby:4.0-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Gemfile Gemfile.lock .ruby-version ./
RUN bundle install --without development test
COPY . .

ENV PORT=8080 RAILS_ENV=production
EXPOSE 8080
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
