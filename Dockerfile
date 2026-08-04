# syntax=docker/dockerfile:1
#
# SecretsUsedInArgOrEnv is skipped for one argument, EDITION_TOKEN, and the
# skip is file-wide because BuildKit has no way to scope it to a line.
#
# The rule is right in general and its recommended fix — `RUN --mount=type=secret`
# — is not available to us: Railway supplies build credentials as build arguments
# and offers no way to pass a BuildKit secret. The mitigation is structural
# instead, and it is the one the editions block below explains at length: the ARG
# is declared inside the throw-away `build` stage, and the final stage copies only
# /rails and the bundle out of it, so neither the value nor the metadata recording
# it reaches the image that ships.
#
# WHAT THIS COSTS: a genuine misuse elsewhere in this file — `ENV STRIPE_SECRET_KEY=…`
# — would no longer be caught here. Everything else `check=error=true` covers stays on.
# check=skip=SecretsUsedInArgOrEnv;error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t tastatur .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name tastatur tastatur

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.4.2
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libvips libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# --- Editions ---------------------------------------------------------------
#
# An edition is a Rails engine in editions/<name>, kept in its own repository and
# loaded by config/application.rb when present (CLAUDE.md §20). This image builds
# the community edition unless told otherwise, which is what a self-hosted build
# wants and is the default below: with EDITION_REPO unset, every line here is a
# no-op and the resulting image is exactly what it was before this block existed.
#
# THE TOKEN LIVES IN THIS STAGE AND NOWHERE ELSE. Build args are recorded in the
# layer history of the stage that declares them, so EDITION_TOKEN would be
# readable from `docker history` on any image that shipped this layer. The final
# stage below is `FROM base` and copies only /rails and the bundle out of here,
# so nothing from this stage's history reaches the image that gets deployed. Do
# not move these ARGs to the top of the file to "tidy them up" — a global ARG is
# in scope for every stage, and that is precisely the mistake.
#
# Use a fine-grained personal access token scoped to the one repository with
# read-only Contents permission. It is the weakest credential that works.
#
# A directory already present is left alone, so a local build with the edition
# checked out (`docker build .` from a working tree) needs no token at all.
ARG EDITION_REPO=""
ARG EDITION_REF="main"
ARG EDITION_NAME="private"
ARG EDITION_TOKEN=""
RUN if [ -n "$EDITION_REPO" ] && [ ! -d "editions/${EDITION_NAME}" ]; then \
      echo "Fetching edition ${EDITION_NAME} from ${EDITION_REPO}@${EDITION_REF}" && \
      git clone --depth 1 --branch "$EDITION_REF" \
        "https://x-access-token:${EDITION_TOKEN}@github.com/${EDITION_REPO}.git" \
        "editions/${EDITION_NAME}" && \
      rm -rf "editions/${EDITION_NAME}/.git"; \
    fi && \
    # Fail loudly rather than shipping a half-built image. An edition that failed
    # to clone would otherwise produce a perfectly healthy container serving the
    # community edition's landing page on the hosted domain — no error, no alert,
    # and the marketing site simply gone.
    if [ -n "$EDITION_REPO" ] && [ ! -f "editions/${EDITION_NAME}/lib/edition.rb" ]; then \
      echo "EDITION_REPO is set but editions/${EDITION_NAME}/lib/edition.rb is missing." >&2; \
      exit 1; \
    fi

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
# Editions carry app/ and lib/ of their own, and are compiled here for the same
# reason — the glob is harmless when the directory does not exist.
RUN bundle exec bootsnap precompile -j 1 app/ lib/ editions/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY.
# This also runs tailwindcss:build, which propshaft then digests along with the
# vendored Archivo woff2 files.
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Bake in the country database.
#
# Baked rather than mounted, because a platform volume is per-service, costs
# money, and would have to be populated by hand after every fresh deploy — which
# means country reporting would silently be missing until someone remembered.
# The file is ~8 MB and DB-IP Lite is CC BY 4.0, so redistributing it inside the
# image is permitted provided the attribution on /privacy stays.
#
# Build with --build-arg WITH_GEOIP=0 to skip it (offline or air-gapped builds).
# Without the file the app still works; country breakdowns are simply empty.
ARG WITH_GEOIP=1
RUN if [ "$WITH_GEOIP" = "1" ]; then \
      SECRET_KEY_BASE_DUMMY=1 ./bin/rails tastatur:geoip:download || \
      echo "GeoIP download failed; continuing without it. Country reporting will be disabled."; \
    fi




# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
