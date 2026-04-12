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
import 'screens/admin_screens.dart';
import 'providers/providers.dart';

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
class SynapseApp extends ConsumerWidget {
  const SynapseApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Route<dynamic> guardedRoute(
      RouteSettings settings,
      Widget child, {
      bool requireAuth = true,
      Set<String>? allowedRoles,
    }) {
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => _RouteGuard(
          requireAuth: requireAuth,
          allowedRoles: allowedRoles,
          child: child,
        ),
      );
    }

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
      initialRoute: '/',
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/':
            return guardedRoute(settings, const AuthGate(), requireAuth: false);

          // Auth
          case '/login':
            return guardedRoute(settings, const LoginScreen(), requireAuth: false);
          case '/register':
            return guardedRoute(settings, const RegisterScreen(), requireAuth: false);

          // Lawyer routes
          case '/lawyer-dashboard':
            return guardedRoute(settings, const LawyerDashboard(), allowedRoles: _lawyerRole);
          case '/case-list':
          case '/case-detail':
          case '/lawyer-tasks':
          case '/lawyer-assignments':
          case '/court-calendar':
          case '/lawyer-work':
          case '/my-tasks':
          case '/intern-assignments':
          case '/intern-tasks':
          case '/my-cases':
          case '/personal-calendar':
          case '/create-reminder':
          case '/shared-calendar':
          case '/home-calendar':
          case '/calendar-event-chat':
          case '/create-chat':
          case '/create-notice':
          case '/courtroom-sos':
          case '/document-generator':
          case '/legal-tools':
          case '/ecourts-import':
            return guardedRoute(
              settings,
              _routeWidget(settings.name!),
              allowedRoles: _staffRoles,
            );

          // Intern dashboard
          case '/intern-dashboard':
            return guardedRoute(settings, const InternDashboard(), allowedRoles: _internRole);

          // Admin dashboard
          case '/admin-dashboard':
            return guardedRoute(settings, const AdminDashboardScreen(), allowedRoles: _adminRole);

          // Routes shared by all authenticated roles
          case '/messenger':
          case '/messages':
          case '/notice-board':
          case '/notices':
          case '/notifications':
            return guardedRoute(
              settings,
              _routeWidget(settings.name!),
              allowedRoles: _allRoles,
            );

          // Client routes
          case '/client-dashboard':
          case '/client-cases':
          case '/case-progress':
          case '/client-documents':
          case '/client-calendar':
          case '/lawyer-contact':
            return guardedRoute(
              settings,
              _routeWidget(settings.name!),
              allowedRoles: _clientRole,
            );

          // Settings
          case '/settings-lawyer':
            return guardedRoute(
              settings,
              const SettingsScreen(userRole: 'Lawyer'),
              allowedRoles: _lawyerRole,
            );
          case '/settings-intern':
            return guardedRoute(
              settings,
              const SettingsScreen(userRole: 'Intern'),
              allowedRoles: _internRole,
            );
          case '/settings-client':
            return guardedRoute(
              settings,
              const SettingsScreen(userRole: 'Client'),
              allowedRoles: _clientRole,
            );

          default:
            return guardedRoute(settings, const AuthGate(), requireAuth: false);
        }
      },
    );
  }
}

const Set<String> _allRoles = {'lawyer', 'intern', 'client', 'admin'};
const Set<String> _staffRoles = {'lawyer', 'intern', 'admin'};
const Set<String> _lawyerRole = {'lawyer', 'admin'};
const Set<String> _internRole = {'intern'};
const Set<String> _clientRole = {'client'};
const Set<String> _adminRole = {'admin'};

Widget _routeWidget(String routeName) {
  switch (routeName) {
    case '/case-list':
      return const CaseListScreen();
    case '/case-detail':
      return const CaseDetailScreen();
    case '/lawyer-tasks':
      return const LawyerTasksScreen();
    case '/lawyer-assignments':
      return const LawyerAssignmentsScreen();
    case '/court-calendar':
      return const CourtCalendarScreen();
    case '/lawyer-work':
    case '/my-tasks':
    case '/intern-assignments':
    case '/intern-tasks':
      return const LawyerWorkScreen();
    case '/my-cases':
      return const CaseListScreen();
    case '/personal-calendar':
      return const PersonalCalendarScreen();
    case '/create-reminder':
      return const CreateReminderScreen();
    case '/shared-calendar':
    case '/home-calendar':
      return const SharedFirmCalendarScreen();
    case '/calendar-event-chat':
      return const CalendarEventChatScreen();
    case '/messenger':
    case '/messages':
      return const MessengerScreen();
    case '/create-chat':
      return const CreateChatScreen();
    case '/notice-board':
    case '/notices':
      return const NoticeBoardScreen();
    case '/create-notice':
      return const CreateNoticeScreen();
    case '/client-dashboard':
      return const ClientDashboard();
    case '/client-cases':
      return const ClientCasesScreen();
    case '/case-progress':
      return const CaseProgressScreen();
    case '/client-documents':
      return const ClientDocumentsScreen();
    case '/client-calendar':
      return const ClientCalendarScreen();
    case '/lawyer-contact':
      return const LawyerContactScreen();
    case '/notifications':
      return const NotificationsScreen();
    case '/admin-dashboard':
      return const AdminDashboardScreen();
    case '/courtroom-sos':
      return const CourtroomSOSScreen();
    case '/document-generator':
      return const DocumentGeneratorScreen();
    case '/legal-tools':
      return const LegalToolsScreen();
    case '/ecourts-import':
      return const EcourtsImportScreen();
    default:
      return const AuthGate();
  }
}

class _RouteGuard extends ConsumerWidget {
  final bool requireAuth;
  final Set<String>? allowedRoles;
  final Widget child;

  const _RouteGuard({
    required this.requireAuth,
    required this.allowedRoles,
    required this.child,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);
    return authState.when(
      data: (authUser) {
        if (!requireAuth) {
          final isAuthScreen = child is LoginScreen || child is RegisterScreen;
          if (isAuthScreen && authUser != null) {
            return const AuthGate();
          }
          return child;
        }

        if (authUser == null) {
          return const LoginScreen();
        }

        final currentUser = ref.watch(currentUserProvider);
        if (currentUser == null || currentUser.uid != authUser.uid) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            ),
          );
        }

        if (!currentUser.isAdmin && (!currentUser.isActive || !currentUser.isApproved)) {
          return const PendingApprovalScreen();
        }

        final role = currentUser.role.toLowerCase();
        if (allowedRoles != null && !allowedRoles!.contains(role)) {
          return const AuthGate();
        }

        return child;
      },
      loading: () => const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: AppColors.accent),
        ),
      ),
      error: (_, __) => const LoginScreen(),
    );
  }
}