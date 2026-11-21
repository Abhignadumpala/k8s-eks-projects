# ───────────────────────────────────────────────
# Frontend image: nginx serving index.html and forwarding /api to the backend
#   - "unprivileged" nginx: runs as user 101 (not root), listens on 8080
#   - works with a read-only root filesystem (Kubernetes mounts /tmp and
#     /etc/nginx/conf.d as small writable folders)
# ───────────────────────────────────────────────
FROM nginxinc/nginx-unprivileged:1.30-alpine

# Default backend address. In Kubernetes the Helm chart sets it.
ENV BACKEND_URL=http://backend:8080

# Files in /etc/nginx/templates/*.template are rendered with env vars at startup
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 8080
