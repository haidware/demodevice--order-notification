# Haidware Staff Inbox

This repository contains the standalone Flutter web app for hotel staff. Staff
sign in with the username and password created by their manager in the
Haidware admin portal. The inbox displays only orders and service requests
assigned to that staff account.

The app is installable as a PWA from its Railway HTTPS domain. It polls the
inbox every eight seconds while open and can register browser push notifications
after the staff member enables them.

## Local development

```powershell
flutter pub get
flutter run -d chrome --dart-define=STAFF_API_BASE_URL=https://device-demo-production.up.railway.app/api/v1
```

## Deployment

Railway builds this repository with its `Dockerfile` and serves it on port 8080.
The app uses the production admin API by default. Override
`STAFF_API_BASE_URL` as a Docker build argument to target another API.

The backend must allow this app's HTTPS origin in `CORS_ALLOWED_ORIGINS` and
provide the staff-app token endpoints, Web Push VAPID keys, and staff account
assignments. The push worker is registered at `/static/` so it does not
interfere with Flutter's root-scope service worker.
