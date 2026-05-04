FROM openresty/openresty:bullseye
RUN apt-get update && apt-get install -y --no-install-recommends gettext-base unzip && rm -rf /var/lib/apt/lists/*
COPY integration-files/noname-security-nginx-policy.zip /tmp/noname-nginx.zip
RUN cd /tmp && unzip noname-nginx.zip && \
    mkdir -p /usr/local/openresty/nginx/lua-scripts && \
    cp lua-scripts/*.lua /usr/local/openresty/nginx/lua-scripts/ && \
    rm -rf /tmp/noname-nginx.zip /tmp/lua-scripts /tmp/deploy.sh
# Patch prevention.lua: add type guard so a non-table rules response (JSON string
# returned by the engine when source credentials don't match) doesn't crash the access phase.
RUN sed -i '/return next(tbl) == nil/i\    if type(tbl) ~= "table" then return true end' \
    /usr/local/openresty/nginx/lua-scripts/prevention.lua
COPY docker/nginx/nginx.conf.template /etc/nginx/nginx.conf.template
COPY docker/nginx/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
