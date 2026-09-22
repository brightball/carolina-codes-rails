# Compile native gems and the bootsnap cache, then ship a runtime without a
# C toolchain. The command is the same Puma config Fly boots.
FROM ruby:4.0-slim AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV BUNDLE_APP_CONFIG=/app/.bundle \
    BUNDLE_PATH=/app/vendor/bundle \
    BUNDLE_WITHOUT=development:test \
    RAILS_ENV=production

COPY Gemfile Gemfile.lock .ruby-version ./
RUN bundle config set --local without "development test" \
 && bundle config set --local path vendor/bundle \
 && bundle install

COPY . .
RUN bundle exec bootsnap precompile --gemfile app/ lib/ config/

FROM ruby:4.0-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV PORT=8080 \
    RAILS_ENV=production \
    RUBY_YJIT_ENABLE=1 \
    BUNDLE_APP_CONFIG=/app/.bundle \
    BUNDLE_PATH=/app/vendor/bundle \
    BUNDLE_WITHOUT=development:test

COPY --from=build /app /app

EXPOSE 8080
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
