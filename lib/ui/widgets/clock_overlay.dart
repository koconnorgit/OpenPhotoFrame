import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// A beautiful clock overlay widget with customizable size and position.
class ClockOverlay extends StatefulWidget {
  final String size; // 'small', 'medium', 'large'
  final String position; // 'bottomRight', 'bottomLeft', 'topRight', 'topLeft'
  final bool showDate; // Show day/date in a smaller font under the time
  final bool compactDate; // Use abbreviated day/month names (e.g. Wed, Jun 10)
  final bool separateDateLine; // Put the weekday on its own line above the date
  final String? temperature; // Optional temperature line (e.g. "21.3°C"), null = hidden

  const ClockOverlay({
    super.key,
    required this.size,
    required this.position,
    this.showDate = false,
    this.compactDate = false,
    this.separateDateLine = false,
    this.temperature,
  });

  @override
  State<ClockOverlay> createState() => _ClockOverlayState();
}

class _ClockOverlayState extends State<ClockOverlay> {
  late Timer _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    // Update every second
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  double get _fontSize {
    switch (widget.size) {
      case 'small':
        return 32;
      case 'large':
        return 72;
      case 'medium':
      default:
        return 48;
    }
  }

  // Date sits in a smaller font beneath the time.
  double get _dateFontSize {
    switch (widget.size) {
      case 'small':
        return 14;
      case 'large':
        return 24;
      case 'medium':
      default:
        return 18;
    }
  }

  Alignment get _alignment {
    switch (widget.position) {
      case 'bottomLeft':
        return Alignment.bottomLeft;
      case 'topRight':
        return Alignment.topRight;
      case 'topLeft':
        return Alignment.topLeft;
      case 'bottomRight':
      default:
        return Alignment.bottomRight;
    }
  }

  EdgeInsets get _padding {
    const base = 24.0;
    switch (widget.position) {
      case 'bottomLeft':
        return const EdgeInsets.only(left: base, bottom: base);
      case 'topRight':
        return const EdgeInsets.only(right: base, top: base);
      case 'topLeft':
        return const EdgeInsets.only(left: base, top: base);
      case 'bottomRight':
      default:
        return const EdgeInsets.only(right: base, bottom: base);
    }
  }

  // Anchor the time/date column to the same side as the corner it sits in.
  CrossAxisAlignment get _crossAxisAlignment {
    switch (widget.position) {
      case 'bottomLeft':
      case 'topLeft':
        return CrossAxisAlignment.start;
      case 'bottomRight':
      case 'topRight':
      default:
        return CrossAxisAlignment.end;
    }
  }

  // Shadows for readability on any background.
  static const List<Shadow> _shadows = [
    Shadow(
      offset: Offset(2, 2),
      blurRadius: 8,
      color: Colors.black54,
    ),
    Shadow(
      offset: Offset(-1, -1),
      blurRadius: 4,
      color: Colors.black26,
    ),
  ];

  /// Builds the date text line(s) shown under the time.
  ///
  /// Returns one combined line ("Wednesday, June 10") normally, or two lines
  /// (weekday then date) when [ClockOverlay.separateDateLine] is set. Names are
  /// abbreviated when [ClockOverlay.compactDate] is set.
  List<String> _dateLines(DateTime date) {
    // Get platform locale (e.g. "de_DE.UTF-8" on Linux)
    final platformLocale = Platform.localeName;
    // Extract language code (e.g. "de_DE" from "de_DE.UTF-8")
    final localeCode = platformLocale.split('.').first.replaceAll('-', '_');

    if (widget.separateDateLine) {
      final weekday = (widget.compactDate
              ? DateFormat.E(localeCode) // "Wed"
              : DateFormat.EEEE(localeCode)) // "Wednesday"
          .format(date);
      final day = (widget.compactDate
              ? DateFormat.MMMd(localeCode) // "Jun 10"
              : DateFormat.MMMMd(localeCode)) // "June 10"
          .format(date);
      return [weekday, day];
    }

    final combined = (widget.compactDate
            ? DateFormat.MMMEd(localeCode) // "Wed, Jun 10"
            : DateFormat.MMMMEEEEd(localeCode)) // "Wednesday, June 10"
        .format(date);
    return [combined];
  }

  @override
  Widget build(BuildContext context) {
    final timeString = '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';

    final timeText = Text(
      timeString,
      style: TextStyle(
        fontSize: _fontSize,
        fontWeight: FontWeight.w300, // Light weight for elegant look
        color: Colors.white,
        shadows: _shadows,
      ),
    );

    // Smaller lines (date, temperature) share the same understated styling.
    Text smallLine(String text) => Text(
          text,
          style: TextStyle(
            fontSize: _dateFontSize,
            fontWeight: FontWeight.w300,
            color: Colors.white,
            shadows: _shadows,
          ),
        );

    final hasTemperature =
        widget.temperature != null && widget.temperature!.isNotEmpty;

    // Drop into a column whenever there's anything beneath the time.
    final Widget content = (widget.showDate || hasTemperature)
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: _crossAxisAlignment,
            children: [
              timeText,
              if (widget.showDate)
                for (final line in _dateLines(_now)) smallLine(line),
              if (hasTemperature) smallLine(widget.temperature!),
            ],
          )
        : timeText;

    return Align(
      alignment: _alignment,
      child: Padding(
        padding: _padding,
        child: content,
      ),
    );
  }
}
