FROM haskell:9.6.6 AS builder

WORKDIR /app

# Copy stack files first for dependency caching
COPY sigil-hs/stack.yaml sigil-hs/stack.yaml.lock sigil-hs/package.yaml ./sigil-hs/

WORKDIR /app/sigil-hs

# Install dependencies (cached layer)
RUN stack setup --no-terminal
RUN stack build --only-dependencies --no-terminal

# Copy source and build
COPY sigil-hs/ /app/sigil-hs/

RUN stack build --no-terminal --copy-bins --local-bin-path /app/bin

# Runtime stage — slim image
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libgmp10 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the built binary
COPY --from=builder /app/bin/sigil-server /app/sigil-server

# Copy static files
COPY sigil-hs/static/ /app/static/

EXPOSE 3000
ENV PORT=3000

CMD ["/app/sigil-server"]
