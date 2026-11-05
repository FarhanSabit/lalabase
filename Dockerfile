# syntax=docker/dockerfile:1
# check=error=true

# The image for running Lalabase yourself with Docker Compose (compose.yml).
# Our own servers do not use it: they deploy with Capistrano.
#
# Each release publishes it as ghcr.io/lalabase/lalabase:<version>, for
# linux/amd64 and linux/arm64 (.github/workflows/docker-release.yml), and
# compose.yml pulls that. To build it from a checkout:
#
#   docker compose -f compose.yml -f compose.build.yml up -d --build
#
# Build it on the architecture it runs on, or with buildx for that platform:
# native extensions do not carry over between arm64 and amd64.

ARG RUBY_VERSION=4.0.7
# trixie pinned: the package names below are Debian 13's (libvips42t64).
FROM docker.io/library/ruby:${RUBY_VERSION}-slim-trixie AS base

WORKDIR /rails

# Runtime libraries only.
# * libvips 8.13+ is required: Rails calls Vips.block_untrusted at boot and
#   refuses to start on an older one (trixie ships 8.16).
# * poppler-utils renders PDF previews. MuPDF is left out on purpose (AGPL with
#   a commercial alternative); Rails would pick it up if it were installed.
# * curl is for the health check in compose.yml.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl libjemalloc2 libpq5 libvips42t64 libyaml-0-2 poppler-utils && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# LALABASE_CONTAINER=1 makes Puma listen on PORT instead of the Unix socket
# our servers use (config/puma.rb); RAILS_LOG_TO_STDOUT=1 keeps the log out of
# the container's filesystem (Lalabase::InstanceSettings).
ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    LALABASE_CONTAINER=1 \
    RAILS_LOG_TO_STDOUT=1 \
    PORT=3000


FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock ./
# gcc 14 (trixie) turns incompatible pointer types into an error. stringio
# 3.1.5 from the lockfile passes one to a Ruby 4 C function (an int pointer
# where Ruby 4 declares an enum of the same size) and no longer compiles;
# older compilers, and the ones on our servers, only warn. So the locked
# version is installed first, with Ruby's own flags plus -fpermissive (which
# turns gcc 14's new errors back into those warnings), and bundle install
# finds it in place. Gone once the lockfile moves stringio to a version that
# matches Ruby 4's signature.
RUN gem install --no-document \
      --install-dir "${BUNDLE_PATH}/ruby/$(ruby -e 'print RbConfig::CONFIG["ruby_version"]')" \
      stringio -v "$(sed -n 's/^    stringio (\(.*\))$/\1/p' Gemfile.lock)" -- \
      --with-cflags="$(ruby -e 'print RbConfig::CONFIG["CFLAGS"]') -fpermissive" && \
    bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

COPY . .

# The tree-sitter runtime comes precompiled with its gem, the TypeScript
# grammars do not: they are vendored C sources, compiled here for this
# platform into tmp/tree_sitter.
RUN bin/build-tree-sitter-parsers && \
    bundle exec bootsnap precompile app/ lib/

# Tailwind and the Sprockets bundle. SECRET_KEY_BASE_DUMMY makes Rails and the
# encryption initializer use throwaway keys for this step only; the running
# container gets the real ones from .env, and the secret file the dummy writes
# goes again. LALABASE_HOST is a placeholder on purpose: the compiled CSS
# carries font URLs with the asset host burnt in, and without LALABASE_HOST
# the asset host is our own (Lalabase::InstanceSettings). Every self-hosted
# instance would load its fonts from lalabase.com. The real host is unknown
# here and not needed: a self-hosted instance has no asset host.
RUN SECRET_KEY_BASE_DUMMY=1 LALABASE_HOST=localhost ./bin/rails assets:precompile && \
    rm -f tmp/local_secret.txt


FROM base

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Not root at run time. storage/ holds the uploads and tmp/cache/store the
# Rails cache; both are volumes in compose.yml. Created here so a new volume
# takes their owner from the image.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p log storage tmp/cache/store && \
    chown -R rails:rails log storage tmp
USER 1000:1000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 3000
CMD ["./bin/rails", "server"]
