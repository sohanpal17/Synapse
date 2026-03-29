Future<String> ensureWebNotificationPermission() async => 'unsupported';

Future<void> showWebBrowserNotification({
  required String title,
  required String body,
}) async {
  // No-op on non-web platforms.
}
