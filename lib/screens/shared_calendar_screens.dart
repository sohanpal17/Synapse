import 'package:flutter/material.dart';
import '../main.dart';

// ══════════ SHARED FIRM CALENDAR ══════════

class SharedFirmCalendarScreen extends StatelessWidget {
  const SharedFirmCalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.primary, AppColors.secondary],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    _buildBackButton(context),
                    const SizedBox(width: 16),
                    const Text(
                      'Shared Calendar',
                      style: TextStyle(
                        color: AppColors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              // Body
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(28),
                      topRight: Radius.circular(28),
                    ),
                  ),
                  child: const Center(
                    child: Text(
                      'Shared Firm Calendar\nComing Soon',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: AppColors.textLight,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════ CALENDAR EVENT CHAT ══════════

class CalendarEventChatScreen extends StatelessWidget {
  const CalendarEventChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.primary, AppColors.secondary],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    _buildBackButton(context),
                    const SizedBox(width: 16),
                    const Text(
                      'Event Chat',
                      style: TextStyle(
                        color: AppColors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              // Body
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(28),
                      topRight: Radius.circular(28),
                    ),
                  ),
                  child: const Center(
                    child: Text(
                      'Calendar Event Chat\nComing Soon',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: AppColors.textLight,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Helper widget for back button
Widget _buildBackButton(BuildContext context) {
  return Container(
    width: 40,
    height: 40,
    decoration: BoxDecoration(
      color: AppColors.white.withOpacity(0.1),
      borderRadius: BorderRadius.circular(20),
    ),
    child: IconButton(
      icon: const Icon(Icons.arrow_back, color: AppColors.white, size: 20),
      onPressed: () => Navigator.pop(context),
    ),
  );
}
