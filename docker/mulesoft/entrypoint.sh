#!/bin/sh
set -e

# FLEX_REGISTRATION_YAML is injected from AWS Secrets Manager via ECS task secrets.
# Flex Gateway's /init reads config from /etc/mulesoft/flex-gateway/conf.d (and
# /usr/local/share/...) at startup; the Dockerfile chowns the conf.d dir so the
# nonroot runtime user (uid 65532) can write here.
TARGET=/etc/mulesoft/flex-gateway/conf.d/registration.yaml
printf '%s' "$FLEX_REGISTRATION_YAML" > "$TARGET"

# Diagnostics: write to stderr so it shows in ECS logs alongside the agent output.
echo "[entrypoint] FLEX_REGISTRATION_YAML env length: $(printf '%s' "$FLEX_REGISTRATION_YAML" | wc -c) bytes" >&2
echo "[entrypoint] file written: $TARGET ($(wc -c < "$TARGET") bytes, $(wc -l < "$TARGET") lines)" >&2
echo "[entrypoint] first 3 lines of file:" >&2
head -3 "$TARGET" >&2
echo "[entrypoint] starting /init" >&2

exec /init
