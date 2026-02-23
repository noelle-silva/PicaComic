FROM dart:stable

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libsqlite3-0 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

COPY . .

ENV PICA_BIND=0.0.0.0 \
    PICA_PORT=8080 \
    PICA_STORAGE=/data

RUN mkdir -p /data
VOLUME ["/data"]
EXPOSE 8080

CMD ["dart", "run", "bin/server.dart"]
