FROM swift:noble AS builder

# Install OS updates
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get install -y libjemalloc-dev

# Set up a build area
WORKDIR /build

COPY ./Package.* ./
RUN swift package resolve \
        $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true)

# Copy entire repo into container
COPY . .

# Build everything, with optimizations, with static linking
RUN swift build \
        --static-swift-stdlib \
        -Xlinker -ljemalloc

# Switch to the staging area
WORKDIR /staging

# Copy main executables to staging area
RUN cp "$(swift build --package-path /build --show-bin-path)/EngineIOTestApp" ./

# Copy static swift backtracer binary to staging area
RUN cp "/usr/libexec/swift/linux/swift-backtrace-static" ./

# Copy resources bundled by SPM to staging area
RUN find -L "$(swift build --package-path /build --show-bin-path)/" -regex '.*\.resources$' -exec cp -Ra {} ./ \;

FROM ubuntu:noble AS engine-runner

# Make sure all system packages are up to date, and install only essential packages.
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y \
      libjemalloc2 \
      ca-certificates \
      tzdata \
      libcurl4 \
      libxml2 \
    && rm -r /var/lib/apt/lists/*

# Switch to the new home directory
WORKDIR /app

# Copy built executable and any staged resources from builder
COPY --from=builder /staging /app

# Provide configuration needed by the built-in crash reporter and some sensible default behaviors.
ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static

EXPOSE 3000

CMD ["./EngineIOTestApp"]

FROM node:alpine AS engine-test

# Clone tests repository
ADD https://github.com/socketio/engine.io-protocol.git /tests

# Set up a test area
WORKDIR /tests/test-suite

# Update localhost to be the runner
RUN sed -i 's/localhost/engine-runner/g' test-suite.js

# Use the built-in fetch implementation from modern Node.
# node-fetch shows intermittent socket hang-ups against the current Hummingbird HTTP/1 polling path.
RUN sed -i 's/import fetch from "node-fetch";/const fetch = globalThis.fetch;/' node-imports.js

# Install npm dependencies
RUN --mount=type=cache,target=/app/.npm \
    npm set cache /app/.npm && \
    npm ci
