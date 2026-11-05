# ───────────────────────────────────────────────
# Frontend image: nginx serving index.html + proxying /api to the backend
# Build:  docker build -t <dockerhub-user>/three-tier-frontend:v1 .
# ───────────────────────────────────────────────
FROM nginx:1.27-alpine

# Default backend address (override with -e BACKEND_URL=... or in the Helm values)
ENV BACKEND_URL=http://backend:8080

# Files in /etc/nginx/templates/*.template are rendered with env vars at startup
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80
