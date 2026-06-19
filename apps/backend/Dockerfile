FROM golang:1.23 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/backend .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/backend /backend
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/backend"]
