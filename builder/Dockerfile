FROM node:22-slim

LABEL org.opencontainers.image.source=https://github.com/WybrenKoelmans/Public-BAR-Widgets
LABEL org.opencontainers.image.description="BAR Workshop builder"
LABEL org.opencontainers.image.licenses="GPL-3.0"

WORKDIR /app/builder

# Install dependencies first (layer caching)
COPY builder/package.json builder/package-lock.json* ./
RUN npm install

# Copy the rest of the builder
COPY builder/ ./

WORKDIR /app

CMD ["npx", "--prefix", "builder", "tsx", "builder/src/build.ts"]
