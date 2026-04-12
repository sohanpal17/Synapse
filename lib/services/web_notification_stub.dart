Future<bool> ensureWebPushServiceWorkerReady({
  Duration timeout = const Duration(seconds: 8),
}) async => false;

Future<void> playWebSosBeep({int durationMs = 800}) async {}

Future<String> getWebNotificationPermissionStatus() async => 'unsupported';

Future<String> ensureWebNotificationPermission() async => 'unsupported';

Future<void> showWebBrowserNotification({
  required String title,
  required String body,
}) async {
  // No-op on non-web platforms.
}
