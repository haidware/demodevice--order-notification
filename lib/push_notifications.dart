import 'push_notifications_stub.dart'
    if (dart.library.js_interop) 'push_notifications_web.dart'
    as platform;

Future<Map<String, dynamic>> createPushSubscription(String publicKey) =>
    platform.createPushSubscription(publicKey);

void showForegroundNotification(String title, String body) =>
    platform.showForegroundNotification(title, body);
