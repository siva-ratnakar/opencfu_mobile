import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _onboardingSeenKey = 'opencfu_onboarding_seen';

/// Whether the operator has already been through [OnboardingScreen] on this
/// device. Checked once at startup so it only ever shows on first launch.
Future<bool> hasSeenOnboarding() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_onboardingSeenKey) ?? false;
}

Future<void> _markOnboardingSeen() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_onboardingSeenKey, true);
}

class _Page {
  const _Page({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;
}

const _pages = [
  _Page(
    icon: Icons.camera_alt_rounded,
    title: 'Point, shoot, count',
    body: "Basic Capture uses OpenCFU's recommended settings — one tap and you're counting colonies.",
  ),
  _Page(
    icon: Icons.tune_rounded,
    title: 'Tune it your way',
    body: 'Advanced mode exposes threshold, radius, and filter controls before you open the camera.',
  ),
  _Page(
    icon: Icons.touch_app_rounded,
    title: 'Fix a miscount',
    body: 'Tap a colony to exclude it, or edit the count directly. In Advanced mode you can also tap '
        'empty space to add one the algorithm missed.',
  ),
  _Page(
    icon: Icons.ios_share_rounded,
    title: 'Take your data with you',
    body: 'Scan as many plates as you need in one session, then export the whole batch as PNG, PDF, or CSV.',
  ),
];

/// A one-time, dismissible tour shown before the first ever capture. Skippable
/// at any point; never shown again once finished or skipped.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finish() {
    unawaited(_markOnboardingSeen());
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _pages.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton(onPressed: _finish, child: const Text('Skip')),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) {
                  final page = _pages[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 36),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 128,
                          height: 128,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                          ),
                          child: Icon(page.icon, size: 56, color: Theme.of(context).colorScheme.primary),
                        ),
                        const SizedBox(height: 32),
                        Text(
                          page.title,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          page.body,
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                _pages.length,
                (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: i == _page ? 20 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _page ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: isLast
                  ? FilledButton(
                      onPressed: _finish,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                      child: const Text('Get started'),
                    )
                  : FilledButton.tonal(
                      onPressed: () => _controller.nextPage(duration: const Duration(milliseconds: 260), curve: Curves.easeOut),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                      child: const Text('Next'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
