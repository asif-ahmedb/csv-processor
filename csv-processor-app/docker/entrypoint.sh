#!/bin/sh
set -e

mkdir -p /shared/public/css /shared/public/js /data/uploads /data/history
cp -r /app/static/css/* /shared/public/css/ 2>/dev/null || true
cp -r /app/static/js/* /shared/public/js/ 2>/dev/null || true

gunicorn --bind 127.0.0.1:8080 --workers 2 --threads 4 app:app &
exec nginx -g 'daemon off;'
