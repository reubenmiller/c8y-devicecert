FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /go/bin
COPY ./dist/devicecert_linux_amd64_v1/devicecert ./app
COPY config/application.production.properties ./application.properties
ENV C8Y_LOGGER_HIDE_SENSITIVE=true
CMD ["./app"]
