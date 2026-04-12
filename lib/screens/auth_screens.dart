import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../main.dart';
import '../config/admin_config.dart';
import '../providers/providers.dart';
import '../services/sync_service.dart';
import '../services/notification_service.dart';

// ── Auth Gate: Checks login state ──
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);
    return authState.when(
      data: (user) {
        if (user == null) return const LoginScreen();
        final currentUser = ref.watch(currentUserProvider);
        if (currentUser == null || currentUser.uid != user.uid) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            ),
          );
        }

        NotificationService.syncDeviceTokenForUser(user.uid);

        if (!currentUser.isAdmin && (!currentUser.isActive || !currentUser.isApproved)) {
          return const PendingApprovalScreen();
        }

        switch (currentUser.role) {
          case 'lawyer':
            return const _DashboardLoader(route: '/lawyer-dashboard');
          case 'intern':
            return const _DashboardLoader(route: '/intern-dashboard');
          case 'client':
            return const _DashboardLoader(route: '/client-dashboard');
          case 'admin':
            return const _DashboardLoader(route: '/lawyer-dashboard');
          default:
            return const LoginScreen();
        }
      },
      loading: () => const Scaffold(
          body: Center(child: CircularProgressIndicator(color: AppColors.accent))),
      error: (_, __) => const LoginScreen(),
    );
  }
}

class _DashboardLoader extends StatefulWidget {
  final String route;
  const _DashboardLoader({required this.route});

  @override
  State<_DashboardLoader> createState() => _DashboardLoaderState();
}

class _DashboardLoaderState extends State<_DashboardLoader> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.pushReplacementNamed(context, widget.route);
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
      body: Center(child: CircularProgressIndicator(color: AppColors.accent)));
}

// ══════════ LOGIN SCREEN ══════════
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: AppColors.primary,
        child: Stack(
          children: [
            CustomPaint(painter: _LegalPatternPainter(), size: Size.infinite),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Container(
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: AppColors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withOpacity(0.15),
                            blurRadius: 30,
                            offset: const Offset(0, 10)),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(32)),
                          child: const Icon(Icons.balance,
                              color: AppColors.accent, size: 32),
                        ),
                        const SizedBox(height: 16),
                        const Text('Synapse',
                            style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: AppColors.accent)),
                        const SizedBox(height: 4),
                        Text('Legal Practice Management',
                            style: TextStyle(
                                fontSize: 14, color: Colors.grey[500])),
                        const SizedBox(height: 32),
                        const SizedBox(height: 16),
                        _inputField(emailController, 'EMAIL',
                            'user@synapse.com', Icons.email_outlined),
                        const SizedBox(height: 16),
                        _inputField(passwordController, 'PASSWORD', '••••••••',
                            Icons.lock_outline,
                            isPassword: true),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _loading ? null : _handleLogin,
                            child: _loading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: AppColors.primary))
                                : const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.login, size: 20),
                                      SizedBox(width: 8),
                                      Text('Sign In',
                                          style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14)),
                                    ],
                                  ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text("Don't have an account? ",
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey[400])),
                            GestureDetector(
                              onTap: () =>
                                  Navigator.pushNamed(context, '/register'),
                              child: const Text('Register',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.secondary,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputField(TextEditingController ctrl, String label, String hint,
      IconData icon,
      {bool isPassword = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Colors.grey[500],
                letterSpacing: 0.5)),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey[200]!),
            borderRadius: BorderRadius.circular(12),
          ),
          child: TextField(
            controller: ctrl,
            obscureText: isPassword,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
              prefixIcon: Icon(icon, color: Colors.grey[400], size: 20),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _handleLogin() async {
    if (emailController.text.isEmpty || passwordController.text.isEmpty) {
      _snack('Please enter email and password');
      return;
    }
    setState(() => _loading = true);
    try {
      final authService = ref.read(authServiceProvider);
      final email = emailController.text.trim();
      final password = passwordController.text.trim();
      final user = email.toLowerCase() == kAdminEmail.toLowerCase()
        ? await authService.loginAsAdmin(email, password)
        : await authService.login(email, password);
      if (!mounted) return;
      ref.read(currentUserProvider.notifier).setUser(user);

      // Background sync
      SyncService().fullSync();

      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(context, '/', (_) => false);
    } on FirebaseAuthException catch (e) {
      _snack(e.message ?? 'Login failed');
    } catch (e) {
      _snack('Login failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

// ══════════ REGISTER SCREEN ══════════
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final nameCtrl = TextEditingController();
  final emailCtrl = TextEditingController();
  final passwordCtrl = TextEditingController();
  final confirmPasswordCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  String role = 'lawyer';
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: AppColors.primary,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                    color: AppColors.white,
                    borderRadius: BorderRadius.circular(24)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: const Icon(Icons.arrow_back, color: AppColors.primary),
                      ),
                      const SizedBox(width: 12),
                      const Text('Create Account',
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primary)),
                    ]),
                    const SizedBox(height: 24),
                    _field(nameCtrl, 'Full Name', Icons.person_outline),
                    const SizedBox(height: 12),
                    _field(emailCtrl, 'Email', Icons.email_outlined),
                    const SizedBox(height: 12),
                    _field(phoneCtrl, 'Phone', Icons.phone_outlined,
                      isPhone: true),
                    const SizedBox(height: 12),
                    _field(passwordCtrl, 'Password', Icons.lock_outline,
                        isPassword: true),
                    const SizedBox(height: 12),
                    _field(confirmPasswordCtrl, 'Confirm Password', Icons.lock_outline,
                        isPassword: true),
                    const SizedBox(height: 16),
                    Text('ROLE',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: Colors.grey[500],
                            letterSpacing: 1)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: ['lawyer', 'intern', 'client']
                          .map((r) => ChoiceChip(
                                label: Text(r[0].toUpperCase() + r.substring(1)),
                                selected: role == r,
                                selectedColor: AppColors.accent,
                                onSelected: (_) => setState(() => role = r),
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _loading ? null : _handleRegister,
                        child: _loading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: AppColors.primary))
                            : const Text('Register',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String hint, IconData icon,
      {bool isPassword = false, bool isPhone = false}) {
    return TextField(
      controller: ctrl,
      obscureText: isPassword,
      keyboardType: isPhone ? TextInputType.phone : TextInputType.text,
      inputFormatters: isPhone
          ? [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(10),
            ]
          : null,
      maxLength: isPhone ? 10 : null,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon, size: 20),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        counterText: isPhone ? '' : null,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }

  Future<void> _handleRegister() async {
    if (nameCtrl.text.isEmpty || emailCtrl.text.isEmpty || passwordCtrl.text.isEmpty || phoneCtrl.text.isEmpty) {
      _snack('Please fill all required fields');
      return;
    }
    if (passwordCtrl.text != confirmPasswordCtrl.text) {
      _snack('Passwords do not match');
      return;
    }
    final normalizedPhone = phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (normalizedPhone.length != 10) {
      _snack('Phone number must be exactly 10 digits');
      return;
    }
    setState(() => _loading = true);

    try {
      // Create user immediately via Email/Password 
      final selectedRole = role;
      await _finalizeRegistration(null, selectedRole: selectedRole);
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _snack(e.toString());
    }
  }

  Future<void> _finalizeRegistration(
    PhoneAuthCredential? phoneCredential, {
    required String selectedRole,
  }) async {
    try {
      final authService = ref.read(authServiceProvider);
      
      // We process the standard email/pass creation
      final user = await authService.register(
        name: nameCtrl.text.trim(),
        email: emailCtrl.text.trim(),
        password: passwordCtrl.text.trim(),
        role: selectedRole,
        phone: phoneCtrl.text.trim(),
      );
      
      // If we got a phone credential, link it to the newly created standard account
      if (phoneCredential != null && FirebaseAuth.instance.currentUser != null) {
         try {
           await FirebaseAuth.instance.currentUser!.linkWithCredential(phoneCredential);
         } catch (e) {
           debugPrint('Failed to link phone credential: $e');
         }
      }

      if (!mounted) return;
      ref.read(currentUserProvider.notifier).setUser(user);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Signup request submitted. Please wait for admin approval.'),
          backgroundColor: AppColors.warning,
        ),
      );
      Navigator.pushNamedAndRemoveUntil(context, '/', (_) => false);
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _snack('Registration failed: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _LegalPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.secondary.withOpacity(0.1)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;
    const spacing = 60.0;
    for (double x = 0; x < size.width; x += spacing) {
      for (double y = 0; y < size.height; y += spacing) {
        canvas.drawLine(Offset(x + 30, y + 5), Offset(x + 30, y + 55), paint);
        canvas.drawLine(Offset(x + 15, y + 20), Offset(x + 45, y + 20), paint);
        canvas.drawLine(Offset(x + 20, y + 35), Offset(x + 40, y + 35), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class PendingApprovalScreen extends ConsumerWidget {
  const PendingApprovalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.hourglass_top, size: 56, color: AppColors.warning),
              const SizedBox(height: 16),
              const Text(
                'Approval Pending',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Your account is waiting for admin approval. Please try again later.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.text),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () async {
                  final auth = ref.read(authServiceProvider);
                  final userNotifier = ref.read(currentUserProvider.notifier);
                  await auth.logout();
                  userNotifier.clear();
                  if (!context.mounted) return;
                  Navigator.pushNamedAndRemoveUntil(
                    context,
                    '/login',
                    (_) => false,
                  );
                },
                child: const Text('Sign Out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}