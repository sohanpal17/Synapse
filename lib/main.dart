import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:workmanager/workmanager.dart';
import 'firebase_options.dart';

import 'services/hive_service.dart';
import 'services/notification_service.dart';
import 'services/sync_service.dart';

import 'screens/auth_screens.dart';
import 'screens/lawyer_screens.dart';
import 'screens/intern_screens.dart';
import 'screens/client_screens.dart';
import 'screens/calendar_screens.dart';
import 'screens/messenger_screens.dart';
import 'screens/notice_screens.dart';
import 'screens/settings_screen.dart';
import 'screens/synapse_screens.dart';
import 'screens/ecourts_import_screen.dart';
import 'screens/shared_calendar_screens.dart';

// ==================== APP COLORS ====================
class AppColors {
  static const Color primary = Color(0xFF0F2A44);
  static const Color secondary = Color(0xFF3C6E9F);
  static const Color accent = Color(0xFFE0B973);
  static const Color background = Color(0xFFF4F6F9);
  static const Color text = Color(0xFF2B2E34);
  static const Color white = Colors.white;
  static const Color grey = Color(0xFF9E9E9E);
  static const Color lightGrey = Color(0xFFE0E0E0);
  static const Color success = Color(0xFF4CAF50);
  static const Color error = Color(0xFFE53935);
  static const Color warning = Color(0xFFFF9800);

  // Traffic Light Colors
  static const Color urgencyGreen = Color(0xFF4CAF50);
  static const Color urgencyYellow = Color(0xFFFFB300);
  static const Color urgencyRed = Color(0xFFE53935);

  // Calendar Event Colors
  static const Color hearingBlue = Color(0xFF2196F3);
  static const Color meetingPurple = Color(0xFF9C27B0);
  static const Color deadlineRed = Color(0xFFE53935);
  static const Color textLight = Color(0xFF757575);
}

// ==================== BACKGROUND TASK DISPATCHER ====================
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await Hive.initFlutter();
      await HiveService.init();

      switch (task) {
        case 'syncTask':
          final syncService = SyncService();
          await syncService.processQueue();
          break;
        case 'escalationCheck':
          final syncService = SyncService();
          await syncService.checkEscalations();
          break;
      }
    } catch (e) {
      debugPrint('Background task error: $e');
    }
    return true;
  });
}

Timer? _foregroundEscalationTimer;

void _startForegroundEscalationChecks() {
  _foregroundEscalationTimer?.cancel();
  final syncService = SyncService();

  // Run once at startup so overdue tasks escalate immediately.
  Future.microtask(() async {
    try {
      await syncService.checkEscalations();
    } catch (e) {
      debugPrint('Foreground escalation check failed: $e');
    }
  });

  // Keep checking while the app is open (important on web where Workmanager is unavailable).
  _foregroundEscalationTimer = Timer.periodic(const Duration(minutes: 1), (_) async {
    try {
      await syncService.checkEscalations();
    } catch (e) {
      debugPrint('Foreground periodic escalation check failed: $e');
    }
  });
}

// ==================== MAIN ====================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // We deliberately do NOT enable Firestore persistence for web 
  // to avoid silent IndexedDB locks and infinite hanging on writes.
  // We use our custom Hive implementation for all offline caching anyway.
  if (kIsWeb) {
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: false,
    );

    // Avoid long noisy retry loops in web when Storage CORS is misconfigured.
    FirebaseStorage.instance.setMaxUploadRetryTime(const Duration(seconds: 3));
    FirebaseStorage.instance.setMaxOperationRetryTime(const Duration(seconds: 3));
  }

  // Initialize Hive (offline database)
  await Hive.initFlutter();
  await HiveService.init();

  // Initialize notifications + FCM handlers.
  await NotificationService.init();

  // Initialize Background Tasks (Workmanager not supported on web)
  if (!kIsWeb) {
    Workmanager().initialize(callbackDispatcher, isInDebugMode: false);

    Workmanager().registerPeriodicTask(
      'synapse-sync',
      'syncTask',
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
    );

    Workmanager().registerPeriodicTask(
      'synapse-escalation',
      'escalationCheck',
      frequency: const Duration(minutes: 15),
    );
  }

  _startForegroundEscalationChecks();

  runApp(const ProviderScope(child: SynapseApp()));
}

// ==================== APP ====================
class SynapseApp extends StatelessWidget {
  const SynapseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Synapse',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: AppColors.primary,
        scaffoldBackgroundColor: AppColors.background,
        textTheme: GoogleFonts.interTextTheme(),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.white,
          elevation: 0,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: AppColors.primary,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      home: const AuthGate(),
      routes: {
        // Auth
        '/login': (_) => const LoginScreen(),
        '/register': (_) => const RegisterScreen(),

        // Lawyer Routes
        '/lawyer-dashboard': (_) => const LawyerDashboard(),
        '/case-list': (_) => const CaseListScreen(),
        '/case-detail': (_) => const CaseDetailScreen(),
        '/lawyer-tasks': (_) => const LawyerTasksScreen(),
        '/lawyer-assignments': (_) => const LawyerAssignmentsScreen(),
        '/court-calendar': (_) => const CourtCalendarScreen(),
        '/lawyer-work': (_) => const LawyerWorkScreen(),

        // Intern Routes
        '/intern-dashboard': (_) => const InternDashboard(),

        // Unified Workflow Routes (Interns + Lawyers)
        '/my-tasks': (_) => const LawyerWorkScreen(), // Redirects to Tasks Tab
        '/intern-assignments': (_) => const LawyerWorkScreen(), // Redirects to Assignments Tab
        '/intern-tasks': (_) => const LawyerWorkScreen(), 
        '/my-cases': (_) => const CaseListScreen(), // Unified Cases Tracker

        // Calendar & Reminder Routes
        '/personal-calendar': (_) => const PersonalCalendarScreen(),
        '/create-reminder': (_) => const CreateReminderScreen(),
        '/shared-calendar': (_) => const SharedFirmCalendarScreen(),
        '/home-calendar': (_) => const SharedFirmCalendarScreen(),
        '/calendar-event-chat': (_) => const CalendarEventChatScreen(),

        // Messenger Routes
        '/messenger': (_) => const MessengerScreen(),
        '/messages': (_) => const MessengerScreen(),
        '/create-chat': (_) => const CreateChatScreen(),

        // Notice Board Routes
        '/notice-board': (_) => const NoticeBoardScreen(),
        '/notices': (_) => const NoticeBoardScreen(),
        '/create-notice': (_) => const CreateNoticeScreen(),

        // Client Routes
        '/client-dashboard': (_) => const ClientDashboard(),
        '/client-cases': (_) => const ClientCasesScreen(),
        '/case-progress': (_) => const CaseProgressScreen(),
        '/client-documents': (_) => const ClientDocumentsScreen(),
        '/client-calendar': (_) => const ClientCalendarScreen(),
        '/lawyer-contact': (_) => const LawyerContactScreen(),
        '/notifications': (_) => const NotificationsScreen(),

        // Settings
        '/settings-lawyer': (_) => const SettingsScreen(userRole: 'Lawyer'),
        '/settings-intern': (_) => const SettingsScreen(userRole: 'Intern'),
        '/settings-client': (_) => const SettingsScreen(userRole: 'Client'),

        // Synapse Features
        '/courtroom-sos': (_) => const CourtroomSOSScreen(),
        '/document-generator': (_) => const DocumentGeneratorScreen(),
        '/legal-tools': (_) => const LegalToolsScreen(),
        '/ecourts-import': (_) => const EcourtsImportScreen(),
      },
    );
  }
}