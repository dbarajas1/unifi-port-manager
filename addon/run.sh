#!/usr/bin/with-contenv bashio

# Map HA add-on options → environment variables consumed by port-api.js
export UNIFI_CONTROLLER="$(bashio::config 'controllerUrl')"
export UNIFI_SITE="$(bashio::config 'site')"
export UNIFI_USERNAME="$(bashio::config 'username')"
export UNIFI_PASSWORD="$(bashio::config 'password')"
export UNIFI_DEVICE="$(bashio::config 'deviceName')"
export UNIFI_API_TOKEN="$(bashio::config 'apiToken')"
export PORT="$(bashio::config 'apiPort')"
export LISTEN_ADDR="0.0.0.0"

if bashio::config.has_value 'ucgFiberName'; then
  export UNIFI_UCG_FIBER="$(bashio::config 'ucgFiberName')"
fi

bashio::log.info "UniFi Port Manager starting..."
bashio::log.info "Controller : ${UNIFI_CONTROLLER}"
bashio::log.info "Switch     : ${UNIFI_DEVICE}"
if [ -n "${UNIFI_UCG_FIBER:-}" ]; then
  bashio::log.info "UCG Fiber  : ${UNIFI_UCG_FIBER}"
fi
bashio::log.info "API port   : ${PORT}"

exec node /port-api.js
