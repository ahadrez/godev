FROM golang:1.23 AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /godev .

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=build /godev /app/godev
COPY public/ /app/public/
EXPOSE 8080
ENTRYPOINT ["/app/godev"]
