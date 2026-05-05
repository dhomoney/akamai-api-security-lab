FROM mulesoft/flex-gateway:latest
USER root
RUN mkdir -p /etc/mulesoft/flex-gateway/conf.d && \
    chown -R 65532:0 /etc/mulesoft/flex-gateway/conf.d
USER 65532
COPY --chmod=755 docker/mulesoft/entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
