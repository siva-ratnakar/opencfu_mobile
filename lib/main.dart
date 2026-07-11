import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';

import 'app_mode.dart';
import 'capture_options.dart';
import 'onboarding_screen.dart';
import 'services/local_export.dart';
import 'services/opencfu_engine.dart';

/// Matches the channel name used by the Android app-widget bridge
/// (`MainActivity.kt`) and the iOS Home Screen quick action bridge
/// (`AppDelegate.swift`).
const _shortcutChannel = MethodChannel('opencfu_mobile/shortcut');

/// Displays an [XFile]'s image cross-platform. `Image.file` requires a real
/// filesystem path, which the browser doesn't have -- image_picker/camera_web
/// XFiles there expose a `blob:` URL instead, which `Image.network` loads
/// directly (Flutter web's network image fetch understands blob URLs).
Widget _xFileImage(XFile file, {required BoxFit fit}) {
  if (kIsWeb) {
    return Image.network(file.path, fit: fit);
  }
  return Image.file(File(file.path), fit: fit);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  final seenOnboarding = await hasSeenOnboarding();
  runApp(OpencfuMobileApp(cameras: cameras, showOnboarding: !seenOnboarding));
}

class PlateRecord {
  PlateRecord({
    required this.name,
    required this.colonies,
    required this.excludedCount,
    required this.image,
    required this.capturedAt,
    this.comment = '',
    this.markers = const <ColonyMarker>[],
    this.imageWidth = 0,
    this.imageHeight = 0,
  });

  final String name;

  /// Valid colonies -- what gets counted.
  final int colonies;

  /// Detected objects the algorithm (or the operator, tapping one off)
  /// excluded. Mirrors desktop OpenCFU's N_Excluded export column.
  final int excludedCount;
  final XFile image;
  final DateTime capturedAt;

  /// Optional free-text note (e.g. media, dilution, incubation time). Mirrors
  /// desktop OpenCFU's per-image Comment field.
  final String comment;

  /// Snapshot of the markers shown on screen when this plate was saved --
  /// kept so exports can re-render the photo with its colony overlay
  /// (see `_renderPlateOverlayPng` in ResultsScreen).
  final List<ColonyMarker> markers;

  /// Source-image pixel size, matching [markers]' coordinate space. Zero
  /// when unknown (native engine unavailable).
  final int imageWidth;
  final int imageHeight;

  bool get hasImageSize => imageWidth > 0 && imageHeight > 0;
}

class OpencfuMobileApp extends StatefulWidget {
  const OpencfuMobileApp({super.key, required this.cameras, this.showOnboarding = false});

  final List<CameraDescription> cameras;
  final bool showOnboarding;

  @override
  State<OpencfuMobileApp> createState() => _OpencfuMobileAppState();
}

class _OpencfuMobileAppState extends State<OpencfuMobileApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  ThemeMode _themeMode = ThemeMode.dark;
  late bool _showOnboarding = widget.showOnboarding;

  @override
  void initState() {
    super.initState();
    _shortcutChannel.setMethodCallHandler(_handleShortcutCall);
    _checkLaunchAction();
  }

  void _toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  /// Handles the home-screen widget (Android) / quick action (iOS) tap while
  /// the app is already running, delivered as a native -> Dart method call.
  Future<void> _handleShortcutCall(MethodCall call) async {
    switch (call.method) {
      case 'launchBasicCapture':
        _openBasicCapture();
      case 'launchAdvancedCapture':
        _openAdvancedCapture();
    }
  }

  /// Asks the native side whether this cold start was triggered by the
  /// basic/advanced-capture widget/quick action, once at launch.
  Future<void> _checkLaunchAction() async {
    String? action;
    try {
      action = await _shortcutChannel.invokeMethod<String>('getLaunchAction');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
    switch (action) {
      case 'basicCapture':
        WidgetsBinding.instance.addPostFrameCallback((_) => _openBasicCapture());
      case 'advancedCapture':
        WidgetsBinding.instance.addPostFrameCallback((_) => _openAdvancedCapture());
    }
  }

  void _openBasicCapture() {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    navigator.push(
      MaterialPageRoute(
        builder: (_) => CaptureScreen(
          mode: AppMode.basic,
          cameras: widget.cameras,
          options: CaptureOptions.basic(),
        ),
      ),
    );
  }

  /// Mirrors [_openBasicCapture] for the widget's Advanced tap target --
  /// opens the same options-setup screen as HomeScreen's Advanced entry
  /// point, not straight into the camera, since Advanced mode's whole point
  /// is choosing options before capture.
  void _openAdvancedCapture() {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    navigator.push(
      MaterialPageRoute(builder: (_) => AdvancedSetupScreen(cameras: widget.cameras)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lightScheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0E7490), brightness: Brightness.light);
    final darkScheme = ColorScheme.fromSeed(seedColor: const Color(0xFF51C4B1), brightness: Brightness.dark);

    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'CFU Counter',
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: lightScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, foregroundColor: Colors.black),
      ),
      darkTheme: ThemeData(
        colorScheme: darkScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF05080C),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, foregroundColor: Colors.white),
      ),
      home: _showOnboarding
          ? OnboardingScreen(onDone: () => setState(() => _showOnboarding = false))
          : HomeScreen(
              cameras: widget.cameras,
              themeMode: _themeMode,
              onToggleTheme: _toggleTheme,
            ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.cameras,
    required this.themeMode,
    required this.onToggleTheme,
  });

  final List<CameraDescription> cameras;
  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;

  @override
  Widget build(BuildContext context) {
    final isDark = themeMode == ThemeMode.dark;
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            const _HomeBackdrop(),
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: onToggleTheme,
                    icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (dialogContext) => _InfoDialog(isDark: isDark),
                    ),
                    icon: const Text('(i)', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ShutterButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => CaptureScreen(
                            mode: AppMode.basic,
                            cameras: cameras,
                            options: CaptureOptions.basic(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Basic Capture',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w300,
                            letterSpacing: 0.2,
                          ),
                    ),
                    const SizedBox(height: 14),
                    IconButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => AdvancedSetupScreen(cameras: cameras),
                        ),
                      ),
                      icon: const Icon(Icons.tune_rounded),
                      tooltip: 'Advanced',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AdvancedSetupScreen extends StatefulWidget {
  const AdvancedSetupScreen({super.key, required this.cameras, this.initialOptions, this.forExistingPlate = false});

  final List<CameraDescription> cameras;

  /// Starting point for the controls below. Null means the normal
  /// pre-capture flow, which starts from [CaptureOptions.advancedDefaults].
  final CaptureOptions? initialOptions;

  /// True when opened mid-plate from the capture screen's options chip to
  /// tweak one specific photo's re-analysis options, instead of the normal
  /// pre-capture setup flow -- changes what "done" means: pop back with the
  /// edited options instead of launching a fresh camera session.
  final bool forExistingPlate;

  @override
  State<AdvancedSetupScreen> createState() => _AdvancedSetupScreenState();
}

class _AdvancedSetupScreenState extends State<AdvancedSetupScreen> {
  late CaptureOptions _options = widget.initialOptions ?? CaptureOptions.advancedDefaults();

  void _startCamera() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CaptureScreen(mode: AppMode.pro, cameras: widget.cameras, options: _options),
      ),
    );
  }

  void _applyToPlate() => Navigator.of(context).pop(_options);

  @override
  Widget build(BuildContext context) {
    final onDone = widget.forExistingPlate ? _applyToPlate : _startCamera;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.forExistingPlate ? 'Edit Options' : 'Advanced Setup'),
        actions: [
          TextButton(
            onPressed: onDone,
            child: Text(widget.forExistingPlate ? 'Apply' : 'Camera'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text('Choose the OpenCFU controls you want before capture.', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          _AdvancedSection(
            title: 'Threshold',
            child: Column(
              children: [
                SwitchListTile.adaptive(
                  value: _options.invertThreshold,
                  onChanged: (value) => setState(
                    () => _options = _options.copyWith(
                      thresholdMode: value ? ThresholdMode.inverted : ThresholdMode.normal,
                    ),
                  ),
                  title: const Text('Invert threshold'),
                  subtitle: const Text('Detect light colonies on a dark plate'),
                ),
                SwitchListTile.adaptive(
                  value: _options.autoThreshold,
                  onChanged: (value) => setState(() => _options = _options.copyWith(autoThreshold: value)),
                  title: const Text('Auto threshold'),
                ),
                if (!_options.autoThreshold)
                  ListTile(
                    title: Text('Manual threshold ${(_options.threshold * 255).round()}'),
                    subtitle: Slider(
                      value: _options.threshold,
                      min: 0.05,
                      max: 0.95,
                      divisions: 18,
                      label: '${(_options.threshold * 255).round()}',
                      onChanged: (value) => setState(() => _options = _options.copyWith(threshold: value)),
                    ),
                  ),
              ],
            ),
          ),
          _AdvancedSection(
            title: 'Radius and ROI',
            child: Column(
              children: [
                ListTile(
                  title: Text('Minimum radius ${_options.minRadius.round()} px'),
                  subtitle: Slider(
                    value: _options.minRadius,
                    min: 0,
                    max: 40,
                    divisions: 40,
                    label: '${_options.minRadius.round()} px',
                    onChanged: (value) => setState(() => _options = _options.copyWith(minRadius: value)),
                  ),
                ),
                SwitchListTile.adaptive(
                  value: _options.hasMaxRadius,
                  onChanged: (value) => setState(() => _options = _options.copyWith(hasMaxRadius: value)),
                  title: const Text('Limit maximum radius'),
                  subtitle: const Text('Off = auto max'),
                ),
                if (_options.hasMaxRadius)
                  ListTile(
                    title: Text('Maximum radius ${_options.maxRadius.round()} px'),
                    subtitle: Slider(
                      value: _options.maxRadius,
                      min: 5,
                      max: 120,
                      divisions: 115,
                      label: '${_options.maxRadius.round()} px',
                      onChanged: (value) => setState(
                        () => _options = _options.copyWith(
                          maxRadius: value < _options.minRadius ? _options.minRadius : value,
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: SegmentedButton<MaskMode>(
                    segments: const [
                      ButtonSegment(value: MaskMode.none, label: Text('None')),
                      ButtonSegment(value: MaskMode.auto, label: Text('Auto-detect')),
                      ButtonSegment(value: MaskMode.draw, label: Text('Draw')),
                    ],
                    selected: {_options.maskMode},
                    onSelectionChanged: (selection) =>
                        setState(() => _options = _options.copyWith(maskMode: selection.first)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    switch (_options.maskMode) {
                      MaskMode.none => 'Colonies are counted across the whole photo.',
                      MaskMode.auto => 'The plate boundary is detected automatically after capture.',
                      MaskMode.draw => widget.forExistingPlate
                          ? "Use \"Redraw mask\" below the photo to draw the plate boundary."
                          : "You'll draw the plate boundary after taking your first photo.",
                    },
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          _AdvancedSection(
            title: 'Filters',
            child: Column(
              children: [
                SwitchListTile.adaptive(
                  value: _options.colourFilter,
                  onChanged: (value) => setState(() => _options = _options.copyWith(colourFilter: value)),
                  title: const Text('Colour filter'),
                  subtitle: const Text('Hue / saturation gate'),
                ),
                SwitchListTile.adaptive(
                  value: _options.outlierFilter,
                  onChanged: (value) => setState(() => _options = _options.copyWith(outlierFilter: value)),
                  title: const Text('Outlier filter'),
                ),
                if (_options.outlierFilter)
                  ListTile(
                    title: Text('Outlier threshold ${_options.outlierThreshold.round()}'),
                    subtitle: Slider(
                      value: _options.outlierThreshold,
                      min: 5,
                      max: 60,
                      divisions: 55,
                      label: '${_options.outlierThreshold.round()}',
                      onChanged: (value) => setState(() => _options = _options.copyWith(outlierThreshold: value)),
                    ),
                  ),
                SwitchListTile.adaptive(
                  value: _options.similarColours,
                  onChanged: (value) => setState(() => _options = _options.copyWith(similarColours: value)),
                  title: const Text('Similar colours'),
                  subtitle: const Text('Cluster colonies by colour'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onDone,
            icon: Icon(widget.forExistingPlate ? Icons.check_rounded : Icons.camera_alt_rounded),
            label: Text(widget.forExistingPlate ? 'Apply to this plate' : 'Continue to Camera'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          ),
          const SizedBox(height: 8),
          Text(_options.summary, textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelLarge),
        ],
      ),
    );
  }
}

class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            child,
          ],
        ),
      ),
    );
  }
}

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, required this.mode, required this.cameras, required this.options});

  final AppMode mode;
  final List<CameraDescription> cameras;
  final CaptureOptions options;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  /// Minimum tap tolerance, in the image display box's own (unzoomed) logical
  /// pixels -- comfortable to hit with a fingertip regardless of how small the
  /// underlying colony is. Converted to source-image pixels by
  /// _ResultImageView before it reaches us, so it stays a fixed, easy target
  /// no matter the zoom level.
  static const double _tapToleranceLogicalPx = 26;

  /// Shown once per app session (not per plate) -- a researcher scanning
  /// dozens of plates shouldn't see the same instruction on every one.
  static bool _hasShownEditTip = false;

  /// Shown the first time Basic mode gets an empty-space tap, same
  /// once-per-session scope as [_hasShownEditTip]. Scattered later
  /// empty-space taps are assumed to be pinch-zoom/pan gestures, so they stay
  /// silent -- but several taps landing back at the same spot look like a
  /// genuine repeated attempt to add a colony there, so that nudges the tip
  /// again regardless of whether it's already been shown once (see
  /// [_lastEmptyTapPoint]/[_repeatedEmptyTapCount] below).
  static bool _hasShownBasicAddMarkerTip = false;

  /// Shown once per session the first time Advanced mode taps an
  /// already-selected marker again. That pattern means the operator was
  /// actually aiming for the empty space just beside it -- trying to add a
  /// new colony there -- and the tap landed back on the existing one instead
  /// of the gap next to it. That's a precision problem, not a delete
  /// attempt, so this nudges toward zooming in rather than toward the
  /// exclude control.
  static bool _hasShownZoomTip = false;

  /// Where the last empty-space tap landed (source-image pixels), and how
  /// many consecutive empty-space taps have landed within [hitRadius] of it
  /// -- reset per plate in [_resetPerPlateTapState]. Together these detect
  /// "tapping the same spot repeatedly" as distinct from "tapping around
  /// while panning/zooming".
  Offset? _lastEmptyTapPoint;
  int _repeatedEmptyTapCount = 0;

  final ImagePicker _picker = ImagePicker();
  final TextEditingController _plateNameController = TextEditingController();
  final TextEditingController _commentController = TextEditingController();
  final ScreenshotController _resultsShot = ScreenshotController();
  final List<PlateRecord> _records = <PlateRecord>[];
  final OpenCfuEngine _engine = FfiOpenCfuEngine();

  CameraController? _cameraController;
  XFile? _currentImage;
  OpenCfuAnalysis? _analysis;
  List<ColonyMarker> _markers = <ColonyMarker>[];
  int? _selectedMarkerIndex;

  /// Gallery photos picked together in one multi-select, waiting their turn
  /// as separate plates -- [_currentImage] is always the one being reviewed
  /// right now; this is everything queued up behind it. See
  /// [_advanceImportQueue].
  final List<XFile> _importQueue = <XFile>[];

  /// Set to the batch size when a multi-image import starts, purely to show
  /// "Plate X of N" in the app bar while working through it; cleared once
  /// the queue drains back to empty. Null outside of a multi-image batch.
  int? _importBatchTotal;
  bool _cameraReady = false;
  bool _busy = false;
  bool _savingPlate = false;
  bool _showComment = false;
  String? _tipMessage;

  /// Set by typing an exact number (tap the count); cleared the moment the
  /// operator touches the image again, so the two ways of correcting a count
  /// never fight each other -- whichever the operator used most recently wins.
  int? _manualCountOverride;

  /// The colony count as the algorithm last computed it for the current
  /// photo, captured once per analysis run -- lets the count-edit dialog's
  /// refresh action restore "what the algorithm found" without spending
  /// compute re-running analysis.
  int _originalCount = 0;

  /// Mutable working copy of widget.options -- mask points/tool are only
  /// known once a photo exists (the operator draws on the actual image), so
  /// they can't live on the immutable options chosen before the camera opened.
  late CaptureOptions _liveOptions = widget.options;

  /// The live, operator-editable count.
  int get _colonies => _manualCountOverride ?? _markers.where((m) => m.valid).length;

  bool get _canAddMarkers => widget.mode == AppMode.pro;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  @override
  void dispose() {
    _plateNameController.dispose();
    _commentController.dispose();
    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    if (widget.cameras.isEmpty) return;
    final controller = CameraController(widget.cameras.first, ResolutionPreset.high, enableAudio: false);
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _cameraController = controller;
        _cameraReady = true;
      });
    } catch (_) {
      if (mounted) setState(() => _cameraReady = false);
    }
  }

  /// Runs (or reruns) analysis on [image] with the current [_liveOptions],
  /// shared by a brand-new capture/import ([_setImage]) and a re-analysis
  /// after the operator adjusts the mask on the same photo ([_reanalyze]).
  Future<void> _runAnalysis(XFile image) async {
    setState(() => _busy = true);
    try {
      final analysis = await _engine.analyze(image: image, mode: widget.mode, options: _liveOptions);
      if (!mounted) return;
      setState(() {
        _analysis = analysis;
        _markers = List<ColonyMarker>.of(analysis.markers);
        _selectedMarkerIndex = null;
        _manualCountOverride = null;
        _originalCount = _markers.where((m) => m.valid).length;
        _lastEmptyTapPoint = null;
        _repeatedEmptyTapCount = 0;
        _busy = false;
      });
      if (!analysis.available) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(analysis.errorMessage ?? 'OpenCFU native engine unavailable.'),
            duration: const Duration(seconds: 4),
          ),
        );
      } else if (!_hasShownEditTip) {
        _hasShownEditTip = true;
        _showTip(
          _canAddMarkers
              ? 'Tap a colony to exclude it, tap empty space to add one'
              : 'Tap a colony to exclude it, or edit the count below',
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('OpenCFU native engine unavailable: $error')),
      );
    }
  }

  Future<void> _setImage(XFile image) async {
    setState(() {
      _currentImage = image;
      _analysis = null;
      _markers = <ColonyMarker>[];
    });
    await _runAnalysis(image);
  }

  /// Reruns analysis on the same photo, e.g. after the operator adjusts the
  /// drawn mask -- unlike [_setImage] this doesn't reset [_currentImage].
  Future<void> _reanalyze() async {
    final image = _currentImage;
    if (image == null) return;
    await _runAnalysis(image);
  }

  /// Opens the full-screen mask draw tool over the current photo, then
  /// reruns analysis with whatever the operator drew.
  Future<void> _openMaskDraw() async {
    final image = _currentImage;
    final analysis = _analysis;
    if (_busy || image == null || analysis == null || !analysis.hasImageSize) return;
    final result = await Navigator.of(context).push<_MaskDrawResult>(
      MaterialPageRoute(
        builder: (_) => _MaskDrawScreen(
          image: image,
          imageSize: Size(analysis.imageWidth.toDouble(), analysis.imageHeight.toDouble()),
          initialTool: _liveOptions.maskTool,
          initialPoints: _liveOptions.maskPoints,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _liveOptions = _liveOptions.copyWith(maskTool: result.tool, maskPoints: result.points));
    await _reanalyze();
  }

  /// Opens the same options screen used before capture, pre-filled with this
  /// plate's current options, so Advanced mode can tweak threshold/radius/
  /// filters for just this photo and reanalyze it -- without restarting the
  /// whole capture flow. Advanced-mode-only, reached via the options chip.
  Future<void> _editOptionsForPlate() async {
    if (_busy) return;
    final result = await Navigator.of(context).push<CaptureOptions>(
      MaterialPageRoute(
        builder: (_) => AdvancedSetupScreen(
          cameras: widget.cameras,
          initialOptions: _liveOptions,
          forExistingPlate: true,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _liveOptions = result);
    await _reanalyze();
  }

  Future<void> _capture() async {
    if (_cameraController == null || !_cameraReady) return;
    setState(() => _busy = true);
    try {
      final file = await _cameraController!.takePicture();
      await _setImage(XFile(file.path));
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not capture image: $error')));
    }
  }

  /// Picking several photos at once queues them as separate plates, worked
  /// through one after another -- see [_advanceImportQueue], called from
  /// [_nextPlate]/[_resetCurrent] whenever the operator leaves a plate.
  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      // Gallery photos can be far higher resolution than OpenCFU's pipeline
      // needs -- colonies are macroscopic, and every downstream step
      // (thresholding, contour finding, per-object classification) scales
      // with pixel count. Capping the long edge keeps analysis fast without
      // losing the detail colony detection actually needs; camera captures
      // are already bounded by ResolutionPreset.high (720p) so don't need this.
      final images = await _picker.pickMultiImage(imageQuality: 92, maxWidth: 2048, maxHeight: 2048);
      if (images.isEmpty) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      if (images.length > 1) {
        setState(() {
          _importBatchTotal = images.length;
          _importQueue
            ..clear()
            ..addAll(images.skip(1));
        });
      }
      await _setImage(images.first);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not import image(s): $error')));
    }
  }

  void _resetCurrent() {
    setState(() {
      _currentImage = null;
      _analysis = null;
      _markers = <ColonyMarker>[];
      _selectedMarkerIndex = null;
      _manualCountOverride = null;
      _plateNameController.clear();
      _commentController.clear();
      _showComment = false;
      // Discard any drawn mask along with the discarded photo -- otherwise it
      // would silently carry over and apply to the next plate.
      _liveOptions = _liveOptions.copyWith(
        maskTool: widget.options.maskTool,
        maskPoints: widget.options.maskPoints,
      );
    });
    _advanceImportQueue();
  }

  /// Pulls the next photo off a multi-image gallery import queue, if any,
  /// and starts reviewing it as the next plate -- called after leaving the
  /// current plate either way (saved via [_nextPlate] or discarded via
  /// [_resetCurrent]), so working through a multi-select batch doesn't drop
  /// back to the empty capture screen between plates. A no-op outside of a
  /// multi-image batch.
  void _advanceImportQueue() {
    if (_importQueue.isEmpty) {
      if (_importBatchTotal != null) setState(() => _importBatchTotal = null);
      return;
    }
    final next = _importQueue.removeAt(0);
    _setImage(next);
  }

  Future<void> _showTip(String message) async {
    setState(() => _tipMessage = message);
    await Future<void>.delayed(const Duration(seconds: 3));
    if (mounted) setState(() => _tipMessage = null);
  }

  /// Handles a tap on the reviewed plate image, in source-image pixel space
  /// (see _ResultImageView for the coordinate conversion).
  ///
  /// Tapping a not-yet-selected valid marker selects it -- a small button
  /// then appears next to it to exclude it. That extra step is deliberate: a
  /// stray tap while pinch-zooming shouldn't be able to silently drop a
  /// colony. Tapping an already-excluded marker restores it immediately,
  /// since undoing isn't destructive and doesn't need the same guard.
  /// Tapping empty space adds a new marker, but only in Advanced mode --
  /// Basic mode leaves the image read-only; the count below is how you fix a
  /// miscount there.
  void _handleImageTap(Offset point, double hitRadius, PointerDeviceKind kind) {
    // The generous fingertip-sized hit padding below is exactly wrong for a
    // precise pointer: a stylus/mouse tap deliberately placed just beside a
    // colony was landing on that colony's padded hit zone instead of empty
    // space, making it hard to add a new marker right next to an existing
    // one. Precise pointers get the marker's actual drawn radius, nothing
    // added -- touch keeps the padded, easy-to-hit version.
    final isPrecisePointer = kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus ||
        kind == PointerDeviceKind.mouse;

    var hitIndex = -1;
    var bestDistance = double.infinity;
    for (var i = 0; i < _markers.length; i++) {
      final distance = (_markers[i].center - point).distance;
      final effectiveRadius = isPrecisePointer
          ? _markers[i].radius
          : (_markers[i].radius > hitRadius ? _markers[i].radius : hitRadius);
      if (distance <= effectiveRadius && distance < bestDistance) {
        bestDistance = distance;
        hitIndex = i;
      }
    }

    String? tipToShow;
    setState(() {
      _manualCountOverride = null;
      if (hitIndex >= 0) {
        if (_markers[hitIndex].valid) {
          // Re-tapping the already-selected colony, in a mode that can add
          // markers, almost always means the operator was aiming for the
          // empty space just beside it -- trying to add a new colony there
          // -- and the imprecise tap landed back on this one instead. Nudge
          // toward zooming in for more room to place the tap accurately,
          // rather than toward the exclude control, which isn't what
          // they're after.
          if (_canAddMarkers && _selectedMarkerIndex == hitIndex && !_hasShownZoomTip) {
            _hasShownZoomTip = true;
            tipToShow = 'Pinch to zoom in for more precise colony placement';
          }
          _selectedMarkerIndex = hitIndex;
        } else {
          final markers = List<ColonyMarker>.of(_markers);
          markers[hitIndex] = markers[hitIndex].copyWith(valid: true);
          _markers = markers;
          _selectedMarkerIndex = null;
        }
      } else if (_selectedMarkerIndex != null) {
        _selectedMarkerIndex = null; // tapping away just dismisses the confirm button
      } else if (_canAddMarkers) {
        final markers = List<ColonyMarker>.of(_markers);
        // Sized to match the *currently counted* colonies, not excluded ones
        // -- an excluded marker is often oversized debris/an artifact in the
        // first place, so averaging it in would keep dragging new manual
        // markers toward that same wrong size. Only when there's nothing
        // valid to match falls back to a size derived from the tap target.
        final referenceRadii = markers.where((m) => m.valid).map((m) => m.radius).toList();
        final defaultRadius = referenceRadii.isEmpty
            ? hitRadius * 0.6
            : referenceRadii.reduce((a, b) => a + b) / referenceRadii.length;
        markers.add(
          ColonyMarker(center: point, corners: const [], radius: defaultRadius, valid: true, manual: true),
        );
        _markers = markers;
      } else {
        // Basic mode's image is read-only by design (see class doc above),
        // so an empty-space tap likely means the operator expected Advanced
        // mode's add-a-colony behavior. Shown once ever, plus nudged again
        // whenever several taps land back at the same spot -- that pattern
        // reads as a repeated, deliberate attempt rather than incidental
        // taps while panning/zooming around the photo.
        final isSameSpot = _lastEmptyTapPoint != null && (_lastEmptyTapPoint! - point).distance <= hitRadius;
        _repeatedEmptyTapCount = isSameSpot ? _repeatedEmptyTapCount + 1 : 1;
        _lastEmptyTapPoint = point;

        if (!_hasShownBasicAddMarkerTip || _repeatedEmptyTapCount >= 3) {
          _hasShownBasicAddMarkerTip = true;
          _repeatedEmptyTapCount = 0;
          tipToShow = 'Adding colonies on the plate needs Advanced mode';
        }
      }
    });
    if (tipToShow != null) {
      _showTip(tipToShow!);
    }
  }

  /// Confirms excluding the selected marker. Manually-added markers are
  /// removed outright (nothing algorithmic to keep a record of); markers the
  /// native engine found are kept but marked invalid, same as desktop
  /// OpenCFU, so there's still a visible trace of what got rejected.
  void _confirmExcludeSelected() {
    final index = _selectedMarkerIndex;
    if (index == null) return;
    setState(() {
      final markers = List<ColonyMarker>.of(_markers);
      final marker = markers[index];
      if (marker.manual) {
        markers.removeAt(index);
      } else {
        markers[index] = marker.copyWith(valid: false);
      }
      _markers = markers;
      _selectedMarkerIndex = null;
      _manualCountOverride = null;
    });
  }

  Future<void> _editCountManually() async {
    // Guards against editing a still-in-flight analysis's placeholder count
    // -- without this, a real result landing afterward would silently
    // clobber whatever the operator just typed.
    if (_busy) return;
    final entered = await _promptManualCount(context, _colonies, originalCount: _originalCount);
    if (entered != null && mounted) {
      setState(() {
        _manualCountOverride = entered;
        _selectedMarkerIndex = null;
      });
    }
  }

  /// Saves the current plate. If the sample name is missing, prompts for one
  /// (per spec) instead of auto-naming. Returns false if the user cancels the
  /// name prompt, so the caller can keep the current plate on screen.
  ///
  /// [_savingPlate] is set synchronously before the first `await`, so a
  /// double-tap on "Next"/"Finish" can't start two concurrent calls racing on
  /// [_currentImage] and [_records] (the second call bails out immediately).
  Future<bool> _nextPlate() async {
    if (_currentImage == null || _savingPlate) return false;
    setState(() => _savingPlate = true);
    try {
      var name = _plateNameController.text.trim();
      if (name.isEmpty) {
        final entered = await _promptSampleName(context);
        if (entered == null || entered.trim().isEmpty) {
          return false;
        }
        name = entered.trim();
      }
      if (!mounted) return false;

      setState(() {
        _records.add(
          PlateRecord(
            name: name,
            colonies: _colonies,
            excludedCount: _manualCountOverride == null ? _markers.where((m) => !m.valid).length : 0,
            image: _currentImage!,
            capturedAt: DateTime.now(),
            comment: _commentController.text.trim(),
            markers: _markers,
            imageWidth: _analysis?.imageWidth ?? 0,
            imageHeight: _analysis?.imageHeight ?? 0,
          ),
        );
        _currentImage = null;
        _analysis = null;
        _markers = <ColonyMarker>[];
        _selectedMarkerIndex = null;
        _manualCountOverride = null;
        _plateNameController.clear();
        _commentController.clear();
        _showComment = false;
        _liveOptions = _liveOptions.copyWith(
          maskTool: widget.options.maskTool,
          maskPoints: widget.options.maskPoints,
        );
      });
      _advanceImportQueue();
      return true;
    } finally {
      if (mounted) setState(() => _savingPlate = false);
    }
  }

  Future<void> _finish() async {
    if (_savingPlate) return;
    if (_importQueue.isNotEmpty) {
      final proceed = await _promptAbandonQueue(context, _importQueue.length);
      if (proceed != true || !mounted) return;
      // Clear before _nextPlate below -- it calls _advanceImportQueue()
      // internally, which would otherwise pull the next queued photo back
      // in right as we're trying to leave.
      setState(() {
        _importQueue.clear();
        _importBatchTotal = null;
      });
    }
    if (_currentImage != null) {
      final advanced = await _nextPlate();
      if (!advanced) return; // user cancelled the sample-name prompt
    }
    if (_records.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Capture at least one plate first.')),
        );
      }
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ResultsScreen(records: List<PlateRecord>.of(_records), screenshotController: _resultsShot),
      ),
    );
  }

  /// Closing this screen destroys its state, silently taking every plate
  /// captured this session with it -- [_records] only survives past here via
  /// [_finish]. Confirms first whenever there's actually something to lose;
  /// a totally fresh screen (nothing captured, nothing queued) just closes.
  Future<void> _confirmQuit() async {
    if (_currentImage == null && _records.isEmpty && _importQueue.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    final quit = await _promptQuitCapture(context);
    if (quit == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = _currentImage != null;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: _confirmQuit,
        ),
        title: Text(
          _importBatchTotal != null ? 'Plate ${_records.length + 1} of $_importBatchTotal' : 'Plate ${_records.length + 1}',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.check_rounded),
            onPressed: _savingPlate ? null : _finish,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (hasImage)
                        _ResultImageView(
                          image: _currentImage!,
                          imageSize: (_analysis?.hasImageSize ?? false)
                              ? Size(_analysis!.imageWidth.toDouble(), _analysis!.imageHeight.toDouble())
                              : null,
                          markers: _markers,
                          maskContour: _analysis?.maskContour ?? const <Offset>[],
                          selectedMarkerIndex: _selectedMarkerIndex,
                          tapToleranceLogicalPx: _tapToleranceLogicalPx,
                          onImageTap: _busy ? null : _handleImageTap,
                          onExcludeSelected: _confirmExcludeSelected,
                        )
                      else if (_cameraReady && _cameraController != null)
                        CameraPreview(_cameraController!)
                      else
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Color(0xFF121A22), Color(0xFF070B10)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      if (_busy) const _AnalyzingOverlay(),
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 14,
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 220),
                            opacity: _tipMessage == null ? 0 : 1,
                            child: Align(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.72),
                                  borderRadius: BorderRadius.circular(100),
                                ),
                                child: Text(
                                  _tipMessage ?? '',
                                  style: const TextStyle(color: Colors.white, fontSize: 13),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Basic mode's options are fixed (see CaptureOptions.basic) and
            // not operator-facing, so the raw "thr auto (inv) • rad 0+ ..."
            // summary would just be unexplained jargon there. Advanced mode
            // chose these settings deliberately, so it's worth showing --
            // and worth being able to tweak per-plate, hence tappable.
            if (hasImage && widget.mode == AppMode.pro)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ActionChip(
                    avatar: const Icon(Icons.tune_rounded, size: 18),
                    label: Text(_liveOptions.summary),
                    onPressed: _busy ? null : _editOptionsForPlate,
                  ),
                ),
              ),
            if (!hasImage)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                child: Row(
                  children: [
                    IconButton.filledTonal(
                      onPressed: _busy ? null : _import,
                      icon: const Icon(Icons.photo_library_outlined),
                    ),
                    const Spacer(),
                    FloatingActionButton.large(
                      onPressed: _busy ? null : _capture,
                      child: _busy
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.camera_alt_rounded),
                    ),
                    const Spacer(),
                    // A misclicked "Next" lands here with the previous plate
                    // already saved -- offers a way straight to Results
                    // without capturing another plate first, in case that's
                    // what the operator actually meant to do. Nothing to
                    // finish before the first plate, so this stays a blank
                    // spacer (matching the import button's width) until then.
                    _records.isNotEmpty
                        ? IconButton.filledTonal(
                            onPressed: (_busy || _savingPlate) ? null : _finish,
                            icon: const Icon(Icons.flag_rounded),
                            tooltip: 'Finish',
                          )
                        : const SizedBox(width: 48),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Card(
                  color: Theme.of(context).colorScheme.surface,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            InkWell(
                              onTap: _editCountManually,
                              borderRadius: BorderRadius.circular(8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _colonies.toString(),
                                    style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  const SizedBox(width: 2),
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Icon(
                                      Icons.edit_rounded,
                                      size: 14,
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _analysis?.overlayLabel ?? 'Waiting for analysis',
                                style: Theme.of(context).textTheme.labelLarge,
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              onPressed: () => setState(() => _showComment = !_showComment),
                              tooltip: 'Note',
                              icon: Icon(
                                _showComment || _commentController.text.isNotEmpty
                                    ? Icons.sticky_note_2_rounded
                                    : Icons.sticky_note_2_outlined,
                              ),
                            ),
                          ],
                        ),
                        if (_showComment)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: TextField(
                              controller: _commentController,
                              autofocus: true,
                              minLines: 1,
                              maxLines: 3,
                              decoration: const InputDecoration(
                                hintText: 'Note (media, dilution, incubation...)',
                                isDense: true,
                              ),
                            ),
                          ),
                        if (_liveOptions.maskMode == MaskMode.draw)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton.icon(
                                onPressed: _busy ? null : _openMaskDraw,
                                icon: const Icon(Icons.gesture_rounded, size: 18),
                                label: Text(_liveOptions.maskPoints.isEmpty ? 'Draw mask' : 'Redraw mask'),
                              ),
                            ),
                          ),
                        Row(
                          children: [
                            IconButton.filledTonal(
                              onPressed: _resetCurrent,
                              icon: const Icon(Icons.delete_outline_rounded),
                              tooltip: 'Reset',
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _plateNameController,
                                decoration: const InputDecoration(hintText: 'Plate Name'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              onPressed: (_busy || _savingPlate) ? null : _nextPlate,
                              icon: const Icon(Icons.arrow_forward_rounded),
                              label: const Text('Next'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.tonalIcon(
                                onPressed: (_busy || _savingPlate) ? null : _finish,
                                icon: const Icon(Icons.flag_rounded),
                                label: const Text('Finish'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shown over the captured photo while the native OpenCFU engine analyses
/// it -- analysis can take a few seconds, and a plain spinner gave no sense
/// that anything was actually happening. A scanning line (like an optical
/// plate reader passing over the dish) plus a few sequentially-pulsing dots
/// read as "counting" rather than "frozen".
class _AnalyzingOverlay extends StatefulWidget {
  const _AnalyzingOverlay();

  @override
  State<_AnalyzingOverlay> createState() => _AnalyzingOverlayState();
}

class _AnalyzingOverlayState extends State<_AnalyzingOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.4),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(painter: _ScanLinePainter(progress: _controller.value)),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Analyzing plate',
                        style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 8),
                      ...List.generate(3, (i) {
                        final t = (_controller.value - i * 0.18) % 1.0;
                        final opacity = (0.25 + 1.5 * (0.5 - (t - 0.5).abs())).clamp(0.25, 1.0);
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1.5),
                          child: Opacity(
                            opacity: opacity,
                            child: Container(
                              width: 5,
                              height: 5,
                              decoration: const BoxDecoration(color: Color(0xFF51C4B1), shape: BoxShape.circle),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A slim horizontal band sweeping down then back up, like an optical
/// scanner passing over the plate. Purely decorative; driven by [progress]
/// cycling 0..1.
class _ScanLinePainter extends CustomPainter {
  _ScanLinePainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final t = progress < 0.5 ? progress * 2 : (1 - progress) * 2;
    final y = size.height * t;
    const bandHeight = 46.0;

    final rect = Rect.fromLTWH(0, y - bandHeight / 2, size.width, bandHeight);
    final bandPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFF51C4B1).withValues(alpha: 0.0),
          const Color(0xFF51C4B1).withValues(alpha: 0.5),
          const Color(0xFF51C4B1).withValues(alpha: 0.0),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, bandPaint);

    final linePaint = Paint()
      ..color = const Color(0xFFB9FFF2).withValues(alpha: 0.85)
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
  }

  @override
  bool shouldRepaint(covariant _ScanLinePainter oldDelegate) => oldDelegate.progress != progress;
}

class ResultsScreen extends StatefulWidget {
  const ResultsScreen({super.key, required this.records, required this.screenshotController});

  final List<PlateRecord> records;
  final ScreenshotController screenshotController;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  late final TextEditingController _fileNameController = TextEditingController(
    text: 'opencfu_counts_${DateFormat('yyyy-MM-dd').format(DateTime.now())}',
  );
  String? _savedMessage;
  bool _saving = false;

  /// True once any export/share action has actually run -- gates whether
  /// the Home button warns before leaving (see [_goHome]).
  bool _hasExported = false;

  bool get _hasComments => widget.records.any((r) => r.comment.isNotEmpty);
  bool get _hasExcluded => widget.records.any((r) => r.excludedCount > 0);

  /// Falls back to the date-based default if the operator clears the field.
  String get _baseFileName {
    final custom = _fileNameController.text.trim();
    return custom.isEmpty ? 'opencfu_counts_${DateFormat('yyyy-MM-dd').format(DateTime.now())}' : custom;
  }

  @override
  void dispose() {
    _fileNameController.dispose();
    super.dispose();
  }

  Future<Directory> _ensureExportDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}opencfu_exports');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Copies a just-written export into a persistent, user-visible "OpenCFU"
  /// device folder (see `services/local_export.dart`) -- the app's own
  /// export directory it was first written into is just private staging,
  /// invisible from outside the app. Falls back to the OS share sheet only
  /// when the platform can't grant that (permission denied on old Android;
  /// never happens on Android 10+ or iOS, which need no such permission).
  Future<void> _saveOrShareFile(File file, String label, String mimeType) async {
    if (!mounted) return;
    final bytes = await file.readAsBytes();
    final result = await saveToDeviceFolder(
      fileName: file.uri.pathSegments.last,
      mimeType: mimeType,
      bytes: bytes,
    );
    if (result.saved) return;
    if (!mounted) return;
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], text: 'OpenCFU Mobile $label export'),
    );
  }

  /// Renders [record]'s photo with its colony overlay to PNG bytes, capped
  /// to a reasonable export size -- colonies don't need full sensor
  /// resolution, and keeping this fast matters when a whole batch of plates
  /// is being rendered at once. Uses `screenshot`'s off-screen
  /// `captureFromWidget`, so nothing needs to be visible on screen.
  Future<Uint8List> _renderPlateOverlayPng(PlateRecord record) async {
    const maxDimension = 1600.0;
    final hasSize = record.hasImageSize;
    final naturalSize =
        hasSize ? Size(record.imageWidth.toDouble(), record.imageHeight.toDouble()) : const Size(1200, 900);
    final longestSide = math.max(naturalSize.width, naturalSize.height);
    final scale = longestSide > maxDimension ? maxDimension / longestSide : 1.0;
    final renderSize = naturalSize * scale;

    final controller = ScreenshotController();
    final widget = Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: renderSize.width,
        height: renderSize.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Colors.black),
            // BoxFit.contain, not fill: renderSize is normally sized to
            // match the image's own aspect ratio (see naturalSize above),
            // but when that assumption breaks -- no reported size, or a
            // mismatch between the analysis dimensions and the actual file
            // -- fill would stretch the plate photo to fill this box instead
            // of letterboxing it, distorting a genuinely square/round plate.
            _xFileImage(record.image, fit: BoxFit.contain),
            if (hasSize) CustomPaint(painter: _ColonyPainter(markers: record.markers, imageSize: naturalSize)),
          ],
        ),
      ),
    );
    // Web loads the photo asynchronously (a blob: URL fetch+decode, see
    // _xFileImage) instead of the near-instant native file read, so it needs
    // more settle time before the capture reads back blank/partial pixels.
    final delay = Duration(milliseconds: kIsWeb ? 150 : 20);
    return controller.captureFromWidget(widget, pixelRatio: 1.0, delay: delay);
  }

  /// Replaces filesystem-unsafe characters in operator-entered text (plate
  /// names) so it can be used as a file name.
  String _sanitizeFileName(String input) {
    final cleaned = input.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return cleaned.isEmpty ? 'plate' : cleaned;
  }

  /// Saves a batch of PNGs (per-plate overlays + the results table image)
  /// together into one "OpenCFU/<folder>" device folder. Falls back to
  /// sharing the whole batch as one multi-file share only if the platform
  /// can't grant folder access -- tried once via the first file, since
  /// permission is an all-or-nothing gate for the whole batch.
  Future<void> _saveOrSharePngBatch(String folder, Map<String, Uint8List> pngs) async {
    if (!mounted || pngs.isEmpty) return;
    final entries = pngs.entries.toList();
    final first = await saveToDeviceFolder(
      fileName: entries.first.key,
      mimeType: 'image/png',
      bytes: entries.first.value,
      subfolder: folder,
    );
    if (first.saved) {
      for (final entry in entries.skip(1)) {
        await saveToDeviceFolder(fileName: entry.key, mimeType: 'image/png', bytes: entry.value, subfolder: folder);
      }
      return;
    }

    if (!mounted) return;
    final dir = await _ensureExportDir();
    final files = <XFile>[];
    for (final entry in entries) {
      final file = File('${dir.path}${Platform.pathSeparator}${entry.key}');
      await file.writeAsBytes(entry.value);
      files.add(XFile(file.path));
    }
    await SharePlus.instance.share(ShareParams(files: files, text: 'OpenCFU Mobile PNG export ($folder)'));
  }

  /// Builds the export PDF's bytes -- kept dart:io-free so it can be reused
  /// for both the native (write-to-file) and web (trigger-a-download) save
  /// paths in [_savePdf].
  Future<Uint8List> _buildPdfBytes() async {
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm');
    final headers = ['Plate name', 'Colonies', if (_hasExcluded) 'Excluded', if (_hasComments) 'Comment', 'Captured'];
    final data = widget.records
        .map(
          (record) => [
            record.name,
            record.colonies.toString(),
            if (_hasExcluded) record.excludedCount.toString(),
            if (_hasComments) record.comment,
            dateFormat.format(record.capturedAt),
          ],
        )
        .toList(growable: false);

    final document = pw.Document();
    document.addPage(
      pw.Page(
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('CFU Counter', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 16),
            pw.TableHelper.fromTextArray(headers: headers, data: data),
          ],
        ),
      ),
    );

    // One page per plate, its photo overlaid with the colonies identified on
    // it -- reuses the same overlay render "Save PNGs" uses.
    for (final record in widget.records) {
      final overlay = await _renderPlateOverlayPng(record);
      final image = pw.MemoryImage(overlay);
      document.addPage(
        pw.Page(
          build: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                '${record.name} — ${record.colonies} colonies',
                style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
              ),
              pw.SizedBox(height: 8),
              pw.Expanded(child: pw.Image(image, fit: pw.BoxFit.contain)),
            ],
          ),
        ),
      );
    }

    return document.save();
  }

  /// Writes [_buildPdfBytes] to the native staging directory -- web has no
  /// filesystem to stage into, so [_savePdf] skips this and downloads the
  /// bytes directly instead.
  Future<File> _writePdfFile({required bool saveCopy}) async {
    final bytes = await _buildPdfBytes();
    final dir = await _ensureExportDir();
    final baseFile = File('${dir.path}${Platform.pathSeparator}$_baseFileName.pdf');
    final file = saveCopy
        ? File('${dir.path}${Platform.pathSeparator}${_baseFileName}_copy_${DateTime.now().millisecondsSinceEpoch}.pdf')
        : baseFile;
    await file.writeAsBytes(bytes);
    return file;
  }

  /// Mirrors desktop OpenCFU's summary CSV export (Plate name/Colonies/
  /// Excluded/Comment columns), plus a capture timestamp for batch sessions.
  /// Kept dart:io-free, like [_buildPdfBytes], so both the native and web
  /// save paths in [_saveCsv] can share it.
  Uint8List _buildCsvBytes() {
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm');
    String field(String value) => '"${value.replaceAll('"', '""')}"';

    final buffer = StringBuffer('Plate name,Colonies,Excluded,Comment,Captured at\n');
    for (final record in widget.records) {
      buffer.writeln(
        [
          field(record.name),
          record.colonies.toString(),
          record.excludedCount.toString(),
          field(record.comment),
          field(dateFormat.format(record.capturedAt)),
        ].join(','),
      );
    }

    return Uint8List.fromList(utf8.encode(buffer.toString()));
  }

  Future<bool?> _promptReplace(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Save PDF?'),
        content: const Text('If the file already exists, replace it or save a copy?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Save a copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSaved(String label) async {
    if (!mounted) return;
    setState(() {
      _savedMessage = '$label saved';
      _hasExported = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (mounted) {
      setState(() {
        _savedMessage = null;
      });
    }
  }

  /// Saves the results table plus one overlay photo per plate (each showing
  /// the colonies identified on it), all together in an "OpenCFU/<file
  /// name>" folder -- this is why the button is "Save PNGs", plural.
  Future<void> _savePngs() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final resultsBytes = await widget.screenshotController.capture(pixelRatio: 2.5);
      if (resultsBytes == null) {
        throw StateError('Could not render results PNG.');
      }
      final pngs = <String, Uint8List>{'results.png': resultsBytes};
      final usedNames = <String>{'results'};
      for (final record in widget.records) {
        final overlay = await _renderPlateOverlayPng(record);
        final baseName = _sanitizeFileName(record.name);
        var candidate = baseName;
        var suffix = 2;
        while (!usedNames.add(candidate)) {
          candidate = '${baseName}_$suffix';
          suffix++;
        }
        pngs['$candidate.png'] = overlay;
      }
      await _showSaved('PNGs');
      await _saveOrSharePngBatch(_baseFileName, pngs);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _savePdf() async {
    if (_saving) return;

    // Web has no filesystem to check for an existing file against, and the
    // browser's own download handling (auto-renaming on collision) already
    // covers what the replace-or-copy prompt is for -- skip straight to
    // downloading the bytes.
    if (kIsWeb) {
      setState(() => _saving = true);
      try {
        final bytes = await _buildPdfBytes();
        await _showSaved('PDF');
        await saveToDeviceFolder(fileName: '$_baseFileName.pdf', mimeType: 'application/pdf', bytes: bytes);
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }

    final dir = await _ensureExportDir();
    final baseFile = File('${dir.path}${Platform.pathSeparator}$_baseFileName.pdf');
    final hasExisting = await baseFile.exists();
    if (!mounted) return;
    final replace = hasExisting ? await _promptReplace(context) : true;
    if (replace == null) return;

    setState(() => _saving = true);
    try {
      final file = await _writePdfFile(saveCopy: !replace);
      await _showSaved('PDF');
      await _saveOrShareFile(file, 'PDF', 'application/pdf');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveCsv() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bytes = _buildCsvBytes();
      await _showSaved('CSV');
      if (kIsWeb) {
        await saveToDeviceFolder(fileName: '$_baseFileName.csv', mimeType: 'text/csv', bytes: bytes);
      } else {
        final dir = await _ensureExportDir();
        final file = File('${dir.path}${Platform.pathSeparator}$_baseFileName.csv');
        await file.writeAsBytes(bytes);
        await _saveOrShareFile(file, 'CSV', 'text/csv');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _shareTxt() async {
    final text = widget.records
        .map((record) => record.comment.isEmpty ? '${record.name}: ${record.colonies}' : '${record.name}: ${record.colonies} (${record.comment})')
        .join('\n');
    await SharePlus.instance.share(ShareParams(text: text));
    if (mounted) setState(() => _hasExported = true);
  }

  /// Returns to the home screen to start a new analysis, dropping this whole
  /// session (capture screen included) off the navigator stack. Warns first
  /// if nothing here has actually been saved/shared yet, since that's the
  /// last screen with access to this batch's results.
  Future<void> _goHome() async {
    if (!_hasExported) {
      final proceed = await _promptLeaveWithoutExport(context);
      if (proceed != true || !mounted) return;
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review and Share'),
        actions: [
          IconButton(
            icon: const Icon(Icons.home_rounded),
            tooltip: 'Home',
            onPressed: _goHome,
          ),
        ],
      ),
      body: Stack(
        children: [
          Screenshot(
            controller: widget.screenshotController,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: SingleChildScrollView(
                          child: DataTable(
                            columns: [
                              const DataColumn(label: Text('Plate name')),
                              const DataColumn(label: Text('Colonies')),
                              if (_hasComments) const DataColumn(label: Text('Notes')),
                            ],
                            rows: widget.records
                                .map(
                                  (record) => DataRow(
                                    cells: [
                                      DataCell(Text(record.name)),
                                      DataCell(Text(record.colonies.toString())),
                                      if (_hasComments)
                                        DataCell(
                                          ConstrainedBox(
                                            constraints: const BoxConstraints(maxWidth: 160),
                                            child: Text(record.comment, overflow: TextOverflow.ellipsis),
                                          ),
                                        ),
                                    ],
                                  ),
                                )
                                .toList(growable: false),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _fileNameController,
                      decoration: const InputDecoration(
                        labelText: 'File name',
                        isDense: true,
                        prefixIcon: Icon(Icons.drive_file_rename_outline_rounded),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _savePngs,
                            icon: _saving
                                ? const SizedBox(
                                    height: 16,
                                    width: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.download_rounded),
                            label: const Text('Save PNGs'),
                            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(58)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton.filledTonal(
                          onPressed: _shareTxt,
                          icon: const Icon(Icons.share_rounded),
                          tooltip: 'Share text',
                        ),
                        const SizedBox(width: 8),
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.more_horiz_rounded),
                          onSelected: (value) {
                            if (value == 'pdf') {
                              _savePdf();
                            } else if (value == 'csv') {
                              _saveCsv();
                            }
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(value: 'pdf', child: Text('Save PDF')),
                            PopupMenuItem(value: 'csv', child: Text('Save CSV')),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: _savedMessage == null ? 0 : 1,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 220),
                offset: _savedMessage == null ? const Offset(0, 0.2) : Offset.zero,
                child: IgnorePointer(
                  ignoring: _savedMessage == null,
                  child: Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle_rounded),
                          const SizedBox(width: 10),
                          Expanded(child: Text(_savedMessage ?? '', style: Theme.of(context).textTheme.bodyMedium)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeBackdrop extends StatelessWidget {
  const _HomeBackdrop();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-0.2, -0.3),
          radius: 1.2,
          colors: [
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.16),
            Theme.of(context).scaffoldBackgroundColor,
          ],
        ),
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 170,
        height: 170,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            colors: [Color(0xFFB9FFF2), Color(0xFF4DC0A4), Color(0xFF1B6F68)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 28, offset: const Offset(0, 18)),
          ],
        ),
        child: Center(
          child: Container(
            width: 128,
            height: 128,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.28), width: 1.5),
            ),
            child: const Icon(Icons.camera_alt_rounded, size: 54, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _InfoDialog extends StatelessWidget {
  const _InfoDialog({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('CFU Counter'),
      content: const SingleChildScrollView(
        child: Text(
          'Developer: siva-ratnakar × AI\n\n'
          'Basic Capture uses inverted auto threshold, auto-max radius (0 minimum), auto ROI/mask, '
          'no colour filter, an outlier filter at threshold 30, and no colour clustering.\n\n'
          'Advanced mode lets you tune the main OpenCFU options before you open the camera.\n\n'
          'Counting runs on the native OpenCFU core. If the native library is not linked, the app '
          'reports that the engine is unavailable rather than showing a fabricated count.',
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}

/// The BoxFit.contain mapping between source-image pixels and the display
/// box's own logical pixels. Shared by the painter and the tap handler so
/// "where something is drawn" and "what a tap there means" never drift apart.
class _ContainTransform {
  const _ContainTransform({required this.scale, required this.dx, required this.dy});

  final double scale;
  final double dx;
  final double dy;

  factory _ContainTransform.of(Size boxSize, Size imageSize) {
    final scale = (boxSize.width / imageSize.width) < (boxSize.height / imageSize.height)
        ? boxSize.width / imageSize.width
        : boxSize.height / imageSize.height;
    final drawnW = imageSize.width * scale;
    final drawnH = imageSize.height * scale;
    return _ContainTransform(scale: scale, dx: (boxSize.width - drawnW) / 2, dy: (boxSize.height - drawnH) / 2);
  }

  Offset toBox(Offset imagePoint) => Offset(dx + imagePoint.dx * scale, dy + imagePoint.dy * scale);

  Offset toImage(Offset boxPoint) => Offset((boxPoint.dx - dx) / scale, (boxPoint.dy - dy) / scale);
}

/// The reviewed plate photo with the detected-colony overlay: pinch/drag to
/// zoom and pan, tap a colony to flip it valid/invalid, tap empty space to
/// drop a new marker where the algorithm missed one. [onImageTap] receives
/// the tap already converted to [imageSize]'s coordinate space, plus a hit
/// tolerance in that same space and the input's [PointerDeviceKind], so
/// callers never touch display-transform math themselves.
class _ResultImageView extends StatefulWidget {
  const _ResultImageView({
    required this.image,
    required this.imageSize,
    required this.markers,
    this.maskContour = const <Offset>[],
    required this.selectedMarkerIndex,
    required this.tapToleranceLogicalPx,
    required this.onImageTap,
    required this.onExcludeSelected,
  });

  final XFile image;

  /// Source-image pixel size, when known. Falls back to the display box's own
  /// size (i.e. a 1:1, untransformed space) when the native engine couldn't
  /// report one -- e.g. it's unavailable and the operator is counting purely
  /// by tapping.
  final Size? imageSize;
  final List<ColonyMarker> markers;

  /// The plate mask boundary actually applied (auto-detected or drawn), in
  /// source-image pixel coordinates. Empty when no mask was applied.
  final List<Offset> maskContour;

  /// Index into [markers] the operator just tapped, if any -- shows the
  /// small exclude-confirm button next to it.
  final int? selectedMarkerIndex;
  final double tapToleranceLogicalPx;
  final void Function(Offset imagePoint, double hitRadius, PointerDeviceKind kind)? onImageTap;
  final VoidCallback onExcludeSelected;

  @override
  State<_ResultImageView> createState() => _ResultImageViewState();
}

class _ResultImageViewState extends State<_ResultImageView> {
  // Tracks the operator's current pinch-zoom level so the tap hit-radius can
  // shrink as they zoom in -- without this, zooming in specifically to
  // separate two close-together colonies didn't help: the hit radius stayed
  // calibrated for the unzoomed view, so a tap meant for the empty space
  // beside a detected colony still landed inside its (unshrunk) hit area and
  // selected/deselected it instead of adding a new marker.
  final TransformationController _transformController = TransformationController();

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: _transformController,
      minScale: 1,
      maxScale: 8,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final boxSize = constraints.biggest;
          final effectiveImageSize =
              (widget.imageSize != null && !widget.imageSize!.isEmpty) ? widget.imageSize! : boxSize;
          final transform = _ContainTransform.of(boxSize, effectiveImageSize);
          final selectedMarkerIndex = widget.selectedMarkerIndex;
          final markers = widget.markers;
          final selected =
              (selectedMarkerIndex != null && selectedMarkerIndex < markers.length) ? markers[selectedMarkerIndex] : null;
          final onImageTap = widget.onImageTap;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: onImageTap == null
                ? null
                : (details) {
                    final zoom = _transformController.value.getMaxScaleOnAxis();
                    onImageTap(
                      transform.toImage(details.localPosition),
                      widget.tapToleranceLogicalPx / (transform.scale * zoom),
                      details.kind,
                    );
                  },
            child: Stack(
              fit: StackFit.expand,
              children: [
                _xFileImage(widget.image, fit: BoxFit.contain),
                if (widget.maskContour.isNotEmpty)
                  CustomPaint(
                    painter: _MaskContourPainter(contour: widget.maskContour, imageSize: effectiveImageSize),
                  ),
                CustomPaint(
                  painter: _ColonyPainter(markers: markers, imageSize: effectiveImageSize, selectedIndex: selectedMarkerIndex),
                ),
                if (selected != null)
                  _ExcludeBadge(
                    center: transform.toBox(selected.center),
                    radius: selected.radius * transform.scale,
                    onTap: widget.onExcludeSelected,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The small "exclude this colony" confirm button that appears next to a
/// tapped marker. A deliberate second tap, separate from the marker itself,
/// so a stray touch while pinch-zooming can't silently drop a colony.
class _ExcludeBadge extends StatelessWidget {
  const _ExcludeBadge({required this.center, required this.radius, required this.onTap});

  final Offset center;
  final double radius;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const size = 28.0;
    final clampedRadius = radius.clamp(6.0, 40.0);
    final badgeCenter = center + Offset(clampedRadius + 4, -(clampedRadius + 4));
    return Positioned(
      left: badgeCenter.dx - size / 2,
      top: badgeCenter.dy - size / 2,
      width: size,
      height: size,
      child: Material(
        color: const Color(0xFFFF5252),
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
        ),
      ),
    );
  }
}

/// Draws the plate mask boundary (auto-detected or drawn) as a translucent
/// outline under the colony markers, so the operator can see what OpenCFU
/// actually used to filter colonies.
class _MaskContourPainter extends CustomPainter {
  _MaskContourPainter({required this.contour, required this.imageSize});

  final List<Offset> contour;
  final Size imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || imageSize.isEmpty || contour.length < 2) return;
    final transform = _ContainTransform.of(size, imageSize);

    final path = Path();
    final p0 = transform.toBox(contour.first);
    path.moveTo(p0.dx, p0.dy);
    for (final point in contour.skip(1)) {
      final p = transform.toBox(point);
      path.lineTo(p.dx, p.dy);
    }
    path.close();

    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0xFF51C4B1).withValues(alpha: 0.08);
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFF51C4B1).withValues(alpha: 0.85);
    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _MaskContourPainter oldDelegate) {
    return oldDelegate.contour != contour || oldDelegate.imageSize != imageSize;
  }
}

/// Draws the detected/edited colonies on top of the displayed image.
/// Algorithm-found colonies use OpenCFU's yellow outer / blue inner outline;
/// ones the operator added by hand are a plain teal dot; anything invalidated
/// (by the algorithm, or by the operator tapping it off) is faint red.
class _ColonyPainter extends CustomPainter {
  _ColonyPainter({required this.markers, required this.imageSize, this.selectedIndex});

  final List<ColonyMarker> markers;
  final Size imageSize;

  /// The marker currently showing the exclude-confirm badge, if any -- drawn
  /// with an extra highlight ring so it's unambiguous which one the badge
  /// belongs to when colonies are close together.
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || imageSize.isEmpty) return;
    final transform = _ContainTransform.of(size, imageSize);

    final invalidPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFFFF5252).withValues(alpha: 0.55);
    final validOuter = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFFFFE93B).withValues(alpha: 0.9);
    final validInner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFF2962FF).withValues(alpha: 0.95);
    final manualFill = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0xFF29D9C6).withValues(alpha: 0.85);
    final manualOutline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white.withValues(alpha: 0.9);
    final selectionRing = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.95);

    for (var i = 0; i < markers.length; i++) {
      final marker = markers[i];
      final path = Path();
      if (marker.corners.length == 4) {
        final p0 = transform.toBox(marker.corners[0]);
        path.moveTo(p0.dx, p0.dy);
        for (var i = 1; i < 4; i++) {
          final p = transform.toBox(marker.corners[i]);
          path.lineTo(p.dx, p.dy);
        }
        path.close();
      } else {
        final c = transform.toBox(marker.center);
        // No special-case floor/ceiling for manual markers: they're sized to
        // match nearby valid colonies when added (see _handleImageTap), so
        // clamping here would just make them visibly bigger than the real
        // colonies they're supposed to match at typical zoom levels.
        final radius = marker.radius * transform.scale;
        path.addOval(Rect.fromCircle(center: c, radius: radius));
      }

      if (!marker.valid) {
        canvas.drawPath(path, invalidPaint);
      } else if (marker.manual) {
        canvas.drawPath(path, manualFill);
        canvas.drawPath(path, manualOutline);
      } else {
        canvas.drawPath(path, validOuter);
        canvas.drawPath(path, validInner);
      }

      if (i == selectedIndex) {
        final c = transform.toBox(marker.center);
        final baseRadius = marker.radius * transform.scale;
        canvas.drawCircle(c, baseRadius + 5, selectionRing);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ColonyPainter oldDelegate) {
    return oldDelegate.markers != markers ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.selectedIndex != selectedIndex;
  }
}

/// Returned by [_MaskDrawScreen] when the operator taps Apply; `null` (a
/// cancelled push) means the previous mask configuration should be kept.
class _MaskDrawResult {
  const _MaskDrawResult({required this.tool, required this.points});

  final MaskTool tool;
  final List<Offset> points;
}

/// Full-screen manual plate-mask editor: tap points on the photo to fit a
/// circle (3 taps) or trace a polygon (3+ taps) around the plate; colonies
/// outside the resulting shape are excluded from the count. Mirrors desktop
/// OpenCFU's "Draw mask" dialog (3-point circle / convex polygon), minus its
/// multi-shape +/- controls -- one shape is enough for a single plate photo.
class _MaskDrawScreen extends StatefulWidget {
  const _MaskDrawScreen({
    required this.image,
    required this.imageSize,
    required this.initialTool,
    required this.initialPoints,
  });

  final XFile image;
  final Size imageSize;
  final MaskTool initialTool;
  final List<Offset> initialPoints;

  @override
  State<_MaskDrawScreen> createState() => _MaskDrawScreenState();
}

class _MaskDrawScreenState extends State<_MaskDrawScreen> {
  late MaskTool _tool = widget.initialTool;
  late List<Offset> _points = List<Offset>.of(widget.initialPoints);

  bool get _canApply => _tool == MaskTool.circle ? _points.length == 3 : _points.length >= 3;

  void _handleTap(Offset imagePoint) {
    if (imagePoint.dx < 0 ||
        imagePoint.dy < 0 ||
        imagePoint.dx > widget.imageSize.width ||
        imagePoint.dy > widget.imageSize.height) {
      return; // tapped outside the drawn image (the letterboxed margin)
    }
    if (_tool == MaskTool.circle && _points.length >= 3) {
      return; // circle auto-locks at 3 points -- Undo/Clear to redo
    }
    setState(() => _points = List<Offset>.of(_points)..add(imagePoint));
  }

  void _undo() {
    if (_points.isEmpty) return;
    setState(() => _points = List<Offset>.of(_points)..removeLast());
  }

  void _clear() => setState(() => _points = <Offset>[]);

  void _switchTool(MaskTool tool) {
    if (tool == _tool) return;
    setState(() {
      _tool = tool;
      _points = <Offset>[]; // different geometry -- start fresh
    });
  }

  void _apply() {
    if (!_canApply) return;
    Navigator.of(context).pop(_MaskDrawResult(tool: _tool, points: _points));
  }

  @override
  Widget build(BuildContext context) {
    final hint = switch (_tool) {
      MaskTool.circle when _points.length < 3 => 'Tap 3 points on the plate edge (${_points.length}/3)',
      MaskTool.circle => 'Circle set — tap Apply, or Clear to redo',
      MaskTool.polygon when _points.length < 3 => 'Tap at least 3 points around the plate (${_points.length})',
      MaskTool.polygon => '${_points.length} points — tap Apply, or keep tapping to add more',
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Draw plate mask'),
        actions: [
          TextButton(onPressed: _canApply ? _apply : null, child: const Text('Apply')),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SegmentedButton<MaskTool>(
                segments: const [
                  ButtonSegment(value: MaskTool.circle, label: Text('Circle (3 taps)')),
                  ButtonSegment(value: MaskTool.polygon, label: Text('Polygon')),
                ],
                selected: {_tool},
                onSelectionChanged: (selection) => _switchTool(selection.first),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(hint, style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final transform = _ContainTransform.of(constraints.biggest, widget.imageSize);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (details) => _handleTap(transform.toImage(details.localPosition)),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _xFileImage(widget.image, fit: BoxFit.contain),
                            CustomPaint(
                              painter: _MaskDrawPainter(tool: _tool, points: _points, imageSize: widget.imageSize),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _points.isEmpty ? null : _undo,
                      icon: const Icon(Icons.undo_rounded),
                      label: const Text('Undo'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _points.isEmpty ? null : _clear,
                      icon: const Icon(Icons.clear_rounded),
                      label: const Text('Clear'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Draws the in-progress circle/polygon shape and the tapped points
/// themselves while the operator builds the mask.
class _MaskDrawPainter extends CustomPainter {
  _MaskDrawPainter({required this.tool, required this.points, required this.imageSize});

  final MaskTool tool;
  final List<Offset> points;
  final Size imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || imageSize.isEmpty) return;
    final transform = _ContainTransform.of(size, imageSize);
    final boxPoints = points.map(transform.toBox).toList(growable: false);

    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFF51C4B1).withValues(alpha: 0.9);
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0xFF51C4B1).withValues(alpha: 0.12);

    if (tool == MaskTool.circle && points.length == 3) {
      final circle = _circleFrom3(points[0], points[1], points[2]);
      if (circle != null) {
        final center = transform.toBox(circle.$1);
        final radius = circle.$2 * transform.scale;
        canvas.drawCircle(center, radius, fillPaint);
        canvas.drawCircle(center, radius, strokePaint);
      }
    } else if (tool == MaskTool.polygon && boxPoints.length >= 2) {
      final path = Path()..moveTo(boxPoints[0].dx, boxPoints[0].dy);
      for (final p in boxPoints.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      if (boxPoints.length >= 3) path.close();
      canvas.drawPath(path, fillPaint);
      canvas.drawPath(path, strokePaint);
    }

    final dotPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0xFFB9FFF2);
    for (final p in boxPoints) {
      canvas.drawCircle(p, 5, dotPaint);
    }
  }

  /// Mirrors the native core's 3-point circle fit (MaskROI::circleFrom3,
  /// MaskROI.cpp) purely for this live preview -- the native bridge does the
  /// authoritative fit (and rejects degenerate/near-collinear taps) once the
  /// operator taps Apply.
  (Offset, double)? _circleFrom3(Offset a, Offset b, Offset c) {
    final x1 = a.dx, y1 = a.dy, x2 = b.dx, y2 = b.dy, x3 = c.dx, y3 = c.dy;
    final f = x3 * x3 - x3 * x2 - x1 * x3 + x1 * x2 + y3 * y3 - y3 * y2 - y1 * y3 + y1 * y2;
    final g = x3 * y1 - x3 * y2 + x1 * y2 - x1 * y3 + x2 * y3 - x2 * y1;
    final m = g == 0 ? 0.0 : f / g;
    final cc = (m * y2) - x2 - x1 - (m * y1);
    final d = (m * x1) - y1 - y2 - (x2 * m);
    final e = (x1 * x2) + (y1 * y2) - (m * x1 * y2) + (m * x2 * y1);
    final h = cc / 2;
    final k = d / 2;
    final s = (h * h) + (k * k) - e;
    if (s <= 0 || !s.isFinite) return null;
    final r = math.sqrt(s);
    if (!r.isFinite || r <= 0) return null;
    return (Offset(h.abs(), k.abs()), r);
  }

  @override
  bool shouldRepaint(covariant _MaskDrawPainter oldDelegate) {
    return oldDelegate.points != points || oldDelegate.tool != tool;
  }
}

/// Drops keyboard focus before popping a dialog route. Without this, a
/// still-focused autofocus TextField can still be mid-way through attaching
/// to the FocusScope's InheritedElement when the dialog is torn down in the
/// same frame, tripping the framework's debug-only
/// `assert(_dependents.isEmpty)` in `InheritedElement.debugDeactivated()`
/// (see docs.flutter.dev/testing/errors). Unfocusing first lets that
/// dependency clean up ahead of the pop instead of racing it.
void _unfocusBeforePop(BuildContext dialogContext) {
  FocusScope.of(dialogContext).unfocus();
}

Future<String?> _promptSampleName(BuildContext context) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Plate name'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          hintText: 'Enter a plate name',
        ),
        onSubmitted: (value) {
          _unfocusBeforePop(dialogContext);
          Navigator.of(dialogContext).pop(value);
        },
      ),
      actions: [
        TextButton(
          onPressed: () {
            _unfocusBeforePop(dialogContext);
            Navigator.of(dialogContext).pop();
          },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            _unfocusBeforePop(dialogContext);
            Navigator.of(dialogContext).pop(controller.text);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

/// Warns before "Finish" would silently skip the rest of a multi-image
/// gallery import that's still queued up.
Future<bool?> _promptAbandonQueue(BuildContext context, int remaining) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Finish now?'),
      content: Text(
        remaining == 1
            ? '1 photo from this import is still waiting to be reviewed. Finishing now skips it.'
            : '$remaining photos from this import are still waiting to be reviewed. Finishing now skips them.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Keep reviewing'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Finish anyway'),
        ),
      ],
    ),
  );
}

/// Warns before the close button would silently discard the whole capture
/// session -- every plate captured so far, plus the one on screen if any.
Future<bool?> _promptQuitCapture(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Quit and lose this session?'),
      content: const Text(
        "Closing now discards everything captured so far -- it won't be saved. "
        'To keep it, tap Finish instead.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Discard and quit'),
        ),
      ],
    ),
  );
}

/// Warns before the Home button would leave this results batch behind
/// unsaved -- this is the only screen with access to it.
Future<bool?> _promptLeaveWithoutExport(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Leave without saving?'),
      content: const Text(
        "You haven't saved or shared these results yet -- going home now leaves this batch behind.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Stay here'),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Leave anyway'),
        ),
      ],
    ),
  );
}

/// Sets an exact colony count directly, independent of the marker overlay --
/// for a confluent/too-numerous-to-count plate where tapping individual
/// colonies isn't practical.
Future<int?> _promptManualCount(BuildContext context, int current, {required int originalCount}) async {
  final controller = TextEditingController(text: current.toString());
  final result = await showDialog<int>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Set colony count'),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          hintText: 'Colonies',
          suffixIcon: IconButton(
            // Restores the algorithm's original count for this photo without
            // re-running analysis -- just swaps the text back in, since the
            // number was already computed once and stored.
            onPressed: () {
              controller.text = originalCount.toString();
              controller.selection = TextSelection.collapsed(offset: controller.text.length);
            },
            tooltip: 'Restore original count ($originalCount)',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
        onSubmitted: (value) {
          _unfocusBeforePop(dialogContext);
          Navigator.of(dialogContext).pop(int.tryParse(value.trim()));
        },
      ),
      actions: [
        TextButton(
          onPressed: () {
            _unfocusBeforePop(dialogContext);
            Navigator.of(dialogContext).pop();
          },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            _unfocusBeforePop(dialogContext);
            Navigator.of(dialogContext).pop(int.tryParse(controller.text.trim()));
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}
