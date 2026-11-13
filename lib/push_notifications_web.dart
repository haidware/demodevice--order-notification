import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

@JS('JSON.stringify')
external JSString _jsonStringify(JSAny? value);

void showForegroundNotification(String title, String body) {
  if (web.Notification.permission != 'granted') return;
  web.Notification(
    title,
    web.NotificationOptions(body: body, icon: '/icons/Icon-192.png'),
  );
}

Future<Map<String, dynamic>> createPushSubscription(String publicKey) async {
  final permission = (await web.Notification.requestPermission().toDart).toDart;
  if (permission != 'granted') {
    throw StateError(
      'Allow notifications in your browser settings to receive staff alerts.',
    );
  }

  final registration = await web.window.navigator.serviceWorker
      .register(
        '/static/staff-push-worker.js'.toJS,
        web.RegistrationOptions(scope: '/static/'),
      )
      .toDart;
  final keyBytes = base64Url.decode(base64Url.normalize(publicKey));
  final applicationServerKey = Uint8List.fromList(keyBytes).toJS;
  final subscription = await registration.pushManager
      .subscribe(
        web.PushSubscriptionOptionsInit(
          userVisibleOnly: true,
          applicationServerKey: applicationServerKey,
        ),
      )
      .toDart;
  final decoded = jsonDecode(_jsonStringify(subscription.toJSON()).toDart);
  if (decoded is! Map) {
    throw const FormatException(
      'Browser returned an invalid push subscription.',
    );
  }
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}
