# Synapse

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Push Notifications (Closed App / Background)

Closed-app push notifications require a backend sender. This project uses a Firebase Function trigger on `sos_alerts`.

Deployed triggers now cover:

- SOS alerts (`sos_alerts`)
- Chat messages (`chatGroups/{groupId}/messages/{messageId}`)
- Tasks (`tasks`) and auto-escalation updates
- Assignments (`assignments`)
- Reminders (`reminders`)

### 1) Deploy Cloud Function

1. Install Firebase CLI and login:
	- `npm i -g firebase-tools`
	- `firebase login`
2. Install function dependencies:
	- `cd functions`
	- `npm install`
3. Deploy:
	- `firebase deploy --only functions`

### 2) Web Push Setup (required for browser push)

1. In Firebase Console > Project Settings > Cloud Messaging, generate a Web Push certificate key pair.
2. Start Flutter web with the VAPID key:
	- `flutter run -d chrome --dart-define=FIREBASE_WEB_VAPID_KEY=YOUR_PUBLIC_VAPID_KEY`

### 3) Verify Token Sync

After login, each user document should contain:

- `fcmTokens` (array)
- `fcmTokenUpdatedAt` (timestamp string)

### 4) Important

- Without deploying the function, SOS documents are written to Firestore but no push is sent to closed apps.
- Foreground in-app banners can still appear without backend push.
