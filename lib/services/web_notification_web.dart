import 'dart:html' as html;

Future<String> ensureWebNotificationPermission() async {
  if (!html.Notification.supported) return 'unsupported';
  String permission = html.Notification.permission ?? 'default';
  if (permission == 'default') {
    permission = await html.Notification.requestPermission() ?? 'default';
  }
  return permission;
}

Future<void> showWebBrowserNotification({
  required String title,
  required String body,
}) async {
  final permission = await ensureWebNotificationPermission();

  if (permission == 'granted') {
    html.Notification(
      title,
      body: body,
      icon: 'icons/Icon-192.png',
      tag: 'synapse-sos',
    );
  }
}
