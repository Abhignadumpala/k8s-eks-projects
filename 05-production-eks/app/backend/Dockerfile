# ───────────────────────────────────────────────
# Backend image: Node.js API
#   - Node 24 LTS on Alpine (small image, fewer CVEs)
#   - only production dependencies
#   - runs as user "node" (uid 1000), never root
# ───────────────────────────────────────────────
FROM node:24-alpine

WORKDIR /app

# Copy only the package files first → this layer is cached until dependencies change
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY server.js ./

USER node

ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.js"]
