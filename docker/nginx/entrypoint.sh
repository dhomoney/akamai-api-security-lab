#!/bin/sh
set -e

DNS_RESOLVER=$(grep nameserver /etc/resolv.conf | head -1 | awk '{print $2}')
DNS_RESOLVER="${DNS_RESOLVER:-169.254.169.253}"

export DNS_RESOLVER
envsubst '${APPS_ALB_DNS} ${DNS_RESOLVER}' \
    < /etc/nginx/nginx.conf.template \
    > /usr/local/openresty/nginx/conf/nginx.conf

# Allow ECS task definition to override the source key/index baked into the zip.
# Set NN_SOURCE_KEY and NN_SOURCE_INDEX env vars in the ECS task definition to
# match the registered integration (fetched dynamically by provision-plugins).
LUA_CFG=/usr/local/openresty/nginx/lua-scripts/logger_configuration.lua
if [ -n "$NN_SOURCE_KEY" ]; then
    sed -i "s/NN_SOURCE_KEY = \"[^\"]*\"/NN_SOURCE_KEY = \"$NN_SOURCE_KEY\"/" "$LUA_CFG"
fi
if [ -n "$NN_SOURCE_INDEX" ]; then
    sed -i "s/NN_SOURCE_INDEX = [0-9]*/NN_SOURCE_INDEX = $NN_SOURCE_INDEX/" "$LUA_CFG"
fi

exec /usr/local/openresty/bin/openresty -g "daemon off;"
