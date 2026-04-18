# Synapse

Synapse is a Flutter + Firebase legal practice management app built for Indian litigation teams.
It helps lawyers, interns, and staff coordinate work across cases, tasks, assignments, reminders, chat, and urgent escalations with reliable in-app + push notifications.

## What This App Covers

- Case-centric workflow management
- Task and assignment collaboration with comments
- Reminder planning and visibility controls
- Team chat and member-aware communication
- Escalation flow for overdue/high-priority work
- In-app notifications and FCM push delivery

## Core Features

### Case & Workflow
- Organize work around active legal matters
- Track case-linked tasks and assignments
- Handle status transitions (`inProgress`, `completed`) with role-aware permissions
- Auto-escalation support for tasks requiring broader team action

### Collaboration
- Comment threads on both task and assignment cards
- Chronological comment flow (oldest at top, newest at bottom)
- Per-item comment counters and bottom-sheet discussion UI

### Productivity
- Calendar-friendly reminders
- Per-user clear/hide for completed items
- Reopen-respawn behavior only when items are genuinely completed again

### Notifications
- In-app notifications feed with read/unread state
- Firebase Cloud Functions fan-out for lifecycle events
- Push triggers for:
	- SOS alerts
	- Chat messages
	- Tasks (including escalation updates)
	- Assignments
	- Reminders

## Tech Stack

- Flutter (Dart 3)
- Firebase:
	- Authentication
	- Cloud Firestore
	- Cloud Functions (Node.js)
	- Firebase Storage
	- Firebase Cloud Messaging
- Riverpod for state management
- Hive for local cache/offline-first UX

## Project Structure

```text
lib/
	config/
	models/
	providers/
	screens/
	services/
	utils/
	widgets/
functions/
	index.js
	package.json
android/ ios/ web/ windows/ macos/ linux/
```

## Prerequisites

- Flutter SDK (compatible with `sdk: >=3.1.0 <4.0.0`)
- Firebase project configured for mobile/web targets
- Node.js 22 (for Cloud Functions)
- Firebase CLI

## Local Setup

1. Install dependencies:

```bash
flutter pub get
```

2. Install Firebase Functions dependencies:

```bash
cd functions
npm install
cd ..
```

3. Ensure Firebase config files are present:
- Android: `android/app/google-services.json`
- iOS: `ios/Runner/GoogleService-Info.plist`
- FlutterFire options: `lib/firebase_options.dart`

4. Run the app:

```bash
flutter run
```

## Cloud Functions Setup

Cloud Functions are required for server-authoritative mutations and reliable closed-app push behavior.

1. Login to Firebase:

```bash
npm i -g firebase-tools
firebase login
```

2. Deploy functions:

```bash
firebase deploy --only functions
```

3. (Optional) Run local emulator for functions:

```bash
cd functions
npm run serve
```

## Web Push Setup

For browser push notifications:

1. In Firebase Console -> Project Settings -> Cloud Messaging, generate a Web Push key pair.
2. Run Flutter web with VAPID key:

```bash
flutter run -d chrome --dart-define=FIREBASE_WEB_VAPID_KEY=YOUR_PUBLIC_VAPID_KEY
```

## Notification Token Verification

After user login, each user document should contain:

- `fcmTokens` (array)
- `fcmTokenUpdatedAt` (timestamp)

If functions are not deployed, Firestore writes may succeed but closed-app push delivery will not.

## Build & Release

Common commands:

```bash
flutter analyze
flutter test
flutter build apk
flutter build ios
flutter build web
```

## Security & Access Model (High Level)

- Data visibility is scoped to authenticated users
- Sensitive writes use callable/backend paths where needed
- Role-driven access patterns are enforced in workflow actions
- Participant/member lists drive scoped reads for tasks, assignments, notices, and chats

## Troubleshooting

### Push not received in background/closed state
- Confirm functions are deployed
- Confirm FCM token exists on user doc
- Confirm device/app notification permissions are granted

### Permission-denied errors on mutations
- Verify caller is authenticated
- Verify Firestore rules and callable deployment are in sync
- Prefer callable-backed actions for restricted paths

### Web push not working
- Confirm VAPID key passed via `--dart-define`
- Confirm `web/firebase-messaging-sw.js` is present and served

## About

This repository contains the full Flutter client and Firebase backend needed to run Synapse end-to-end.
It is intended for legal teams that need secure, role-aware, real-time coordination for litigation operations.
