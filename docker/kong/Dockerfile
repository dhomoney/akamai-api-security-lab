FROM kong:latest
USER root
RUN apt-get update && apt-get install -y --no-install-recommends unzip && rm -rf /var/lib/apt/lists/*
COPY integration-files/noname-security-kong-policy.zip /tmp/noname-kong.zip
RUN cd /tmp && unzip noname-kong.zip && \
    luarocks install kong-plugin-nonamesecurity-3.2.7-1.all.rock && \
    rm -rf /tmp/noname-kong.zip /tmp/kong /tmp/spec /tmp/*.rock /tmp/*.rockspec /tmp/.busted
USER kong
