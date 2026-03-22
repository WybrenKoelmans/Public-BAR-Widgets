FROM node:22-slim

LABEL org.opencontainers.image.source=https://github.com/WybrenKoelmans/Public-BAR-Widgets
LABEL org.opencontainers.image.description="BAR Workshop builder"
LABEL org.opencontainers.image.licenses="GPL-3.0"

# Install git (needed for commit date sorting)
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/builder

# Install dependencies first (layer caching)
COPY builder/package.json builder/package-lock.json* ./
RUN npm install

# Copy the rest of the builder
COPY builder/ ./

WORKDIR /app

# Mark /app as safe for git (mounted volume may have different ownership)
RUN git config --global --add safe.directory /app

CMD ["npx", "--prefix", "builder", "tsx", "builder/src/build.ts"]
