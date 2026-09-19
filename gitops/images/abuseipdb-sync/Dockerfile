# syntax=docker/dockerfile:1

# Version inputs are parsed by .github/workflows/build-abuseipdb-sync.yaml to
# derive the image tag. Keep the ARG format stable.
ARG GO_VERSION=1.27
ARG APP_VERSION=0.3.1
ARG IMAGE_REVISION=r1

FROM golang:${GO_VERSION}-alpine AS build
ENV GOTOOLCHAIN=local
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG APP_VERSION
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath \
    -ldflags "-s -w -X main.version=${APP_VERSION}" \
    -o /out/abuseipdb-sync .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/abuseipdb-sync /usr/local/bin/abuseipdb-sync
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/abuseipdb-sync"]
