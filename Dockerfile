# syntax=docker/dockerfile:1
# Versão do Go fixada por ARG para reprodutibilidade. Deve ser >= à diretiva "go" de application/go.mod
# (o CI deve ler a versão de lá: actions/setup-go com go-version-file).
ARG GO_VERSION=1.26

FROM golang:${GO_VERSION}-alpine AS build
WORKDIR /src
COPY application/go.mod application/go.sum ./
RUN go mod download
COPY application/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/api

# Imagem final mínima, sem shell, usuário não-root.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
USER nonroot:nonroot
EXPOSE 8080
# Sem shell/curl na imagem: o próprio binário expõe o subcomando "healthcheck".
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 CMD ["/app", "healthcheck"]
ENTRYPOINT ["/app"]
