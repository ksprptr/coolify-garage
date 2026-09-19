FROM dxflrs/garage:v2.3.0 AS garage-bin

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=garage-bin /garage /garage
COPY garage.toml.template /etc/garage.toml.template
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]