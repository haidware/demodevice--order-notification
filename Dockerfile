FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
ARG STAFF_API_BASE_URL=https://device-demo-production.up.railway.app/api/v1
RUN flutter build web --release --base-href / \
    --dart-define=STAFF_API_BASE_URL=${STAFF_API_BASE_URL}

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build/web /usr/share/nginx/html
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
