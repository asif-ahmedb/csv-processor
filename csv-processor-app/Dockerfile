FROM python:3.12-slim-bookworm AS app

WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends nginx \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default

COPY web/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY web/ /app/
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && mkdir -p /shared/public /data/uploads /data/history \
               /tmp/nginx-client /tmp/nginx-proxy \
    && chown -R www-data:www-data /shared /data /tmp/nginx-client /tmp/nginx-proxy

ENV APP_PORT=8080
ENV UPLOAD_DIR=/data/uploads
ENV HISTORY_FILE=/data/history/processed.json
ENV STATIC_SHARED=/shared/public

USER www-data

EXPOSE 8081

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8081/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
