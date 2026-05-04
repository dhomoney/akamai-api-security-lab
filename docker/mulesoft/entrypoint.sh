#!/bin/sh
set -e

# FLEX_REGISTRATION_YAML is injected from AWS Secrets Manager via ECS task secrets.
# Write it to the path Flex Gateway expects, then start the gateway.
CONF_DIR=/etc/mulesoft/flex-gateway
mkdir -p "$CONF_DIR"
printf '%s' "$FLEX_REGISTRATION_YAML" > "$CONF_DIR/registration.yaml"

exec flexctl run
