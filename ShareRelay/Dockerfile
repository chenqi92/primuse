FROM golang:1.26-alpine AS build

WORKDIR /src
COPY go.mod *.go ./
COPY web ./web
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/primuse-share-relay .

FROM alpine:3.23

RUN addgroup -S relay && adduser -S -G relay -h /data relay
COPY --from=build /out/primuse-share-relay /usr/local/bin/primuse-share-relay

USER relay
VOLUME ["/data"]
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/primuse-share-relay"]
