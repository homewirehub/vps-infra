# Unprivileged nginx: listens on 8080 and runs as uid 101, so the container
# needs no root and no capability to bind a low port.
FROM nginxinc/nginx-unprivileged:1.27-alpine

COPY public/ /usr/share/nginx/html/

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://127.0.0.1:8080/ >/dev/null || exit 1
