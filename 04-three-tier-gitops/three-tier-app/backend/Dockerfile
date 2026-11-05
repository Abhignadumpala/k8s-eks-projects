# ───────────────────────────────────────────────
# Backend image: Node.js API
# Build:  docker build -t <dockerhub-user>/three-tier-backend:v1 .
# ───────────────────────────────────────────────
FROM node:20-alpine

WORKDIR /app

# Copy only package files first → this layer is cached until dependencies change
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY server.js ./

# Don't run as root (the node image ships a "node" user)
USER node

ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.js"]
