# ───────────────────────────────────────────────
# Backend image: Node.js API (multi-stage build)
#   Stage 1 "build": node image WITH npm → installs libraries into /app/node_modules
#   Stage 2 "run":   plain Alpine + only the node binary → NO npm/npx/yarn/corepack
#   - only production dependencies
#   - runs as user "node" (uid 1000), never root
# ───────────────────────────────────────────────

# ---------- Stage 1: build (thrown away after the build) ----------
FROM node:24-alpine AS build

WORKDIR /app

# Copy only the package files first → this layer is cached until dependencies change
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY server.js ./

# ---------- Stage 2: run (this is the image we ship) ----------
# Same Alpine version as node:24-alpine, so the copied node binary works
FROM alpine:3.24

# Security fixes + the C++ library node needs + user "node" (uid 1000)
RUN apk upgrade --no-cache \
 && apk add --no-cache libstdc++ \
 && addgroup -g 1000 node \
 && adduser -u 1000 -G node -s /sbin/nologin -D node

# Take only what the app needs from stage 1: the node binary and /app
COPY --from=build /usr/local/bin/node /usr/local/bin/node

WORKDIR /app
COPY --from=build --chown=node:node /app /app

USER node

ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.js"]
