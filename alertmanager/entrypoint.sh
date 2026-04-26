#!/bin/sh
# BUG-010 PR1: Alertmanager entrypoint — substitutes env var placeholders
# в YAML template (Alertmanager YAML config doesn't expand ${VAR} natively).
# Generated config to /tmp/alertmanager.yml, then exec alertmanager (PID 1
# replacement for proper signal handling).
#
# CR M-1/M-2 + PG iter1 fix: Kamal не accepts cmd as array of strings,
# script file mount = clean alternative. Busybox sh+sed available в
# alertmanager Alpine base image.

set -e

sed \
  -e "s|__TG_BOT_TOKEN__|${TELEGRAM_OPS_BOT_TOKEN}|g" \
  -e "s|__TG_CRITICAL_CHAT_ID__|${TELEGRAM_CRITICAL_CHAT_ID}|g" \
  -e "s|__TG_OPS_CHAT_ID__|${TELEGRAM_OPS_CHAT_ID}|g" \
  -e "s|__TG_INFO_CHAT_ID__|${TELEGRAM_INFO_CHAT_ID}|g" \
  /etc/alertmanager/alertmanager.yml.tmpl > /tmp/alertmanager.yml

exec /bin/alertmanager --config.file=/tmp/alertmanager.yml --storage.path=/alertmanager
