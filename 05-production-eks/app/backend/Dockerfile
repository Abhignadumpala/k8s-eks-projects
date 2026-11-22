# ───────────────────────────────────────────────
# Backend image: Node.js API
#   - Node 24 LTS on Alpine (small image, fewer CVEs)
#   - only production dependencies
#   - runs as user "node" (uid 1000), never root
# ───────────────────────────────────────────────
FROM node:24-alpine

# Get the latest Alpine security fixes (openssl, zlib...)
RUN apk upgrade --no-cache

WORKDIR /app

# Copy only the package files first → this layer is cached until dependencies change
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY server.js ./

# Remove npm, npx, yarn, corepack: needed to install, not to run (they bring CVEs)
RUN rm -rf /usr/local/lib/node_modules /opt/yarn-* /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/yarn /usr/local/bin/yarnpkg /usr/local/bin/corepack

USER node

ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.js"]
