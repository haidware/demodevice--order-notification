Future<Map<String, dynamic>> createPushSubscription(String publicKey) {
  throw UnsupportedError(
    'Browser push notifications are only available on the web.',
  );
}

void showForegroundNotification(String title, String body) {}
