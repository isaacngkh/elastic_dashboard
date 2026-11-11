import 'dart:math';

import 'package:dot_cast/dot_cast.dart';
import 'package:provider/provider.dart';

import 'package:material_ui/material_ui.dart';

import 'package:elastic_dashboard/services/nt4_client.dart';
import 'package:elastic_dashboard/widgets/nt_widgets/nt_widget.dart';

const List<String> reefLevels = ['L4', 'L3', 'L2'];
const List<String> reefBranches = [
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', //
];

/// Screen angle (degrees, clockwise from +x) of the face holding branches A/B.
/// 90 = bottom of the widget. Change this to rotate the whole reef.
const double faceStartDegrees = 90;

// All distances below are fractions of the reef radius (see _reefRadius).
const double _hexApothem = 0.30; // center to the middle of a hexagon edge
const double _branchOffset = 0.09; // how far each branch sits from face center
const double _circleRadius = 0.075; // same for every circle
// Distance from center of the circle for each level: index 0 = L4 (outer)
const List<double> _levelDistance = [0.79, 0.62, 0.45];

double _reefRadius(Size size) => min(size.width, size.height) / 2 * 0.95;

/// Unit vector pointing out of the face that holds [branch].
Offset _faceDirection(int branch) {
  final double theta = (faceStartDegrees + 60.0 * (branch ~/ 2)) * pi / 180;
  return Offset(cos(theta), sin(theta));
}

/// Position of [branch] at [distance] from center (fractions of reef radius).
Offset _branchPoint(
  Size size,
  int branch,
  double distance, {
  double offset = _branchOffset,
}) {
  final Offset dir = _faceDirection(branch);
  final Offset perp = Offset(-dir.dy, dir.dx);
  final double side = branch % 2 == 0 ? 1.0 : -1.0;
  final Offset center = Offset(size.width / 2, size.height / 2);
  return center +
      (dir * distance + perp * (side * offset)) * _reefRadius(size);
}

class ReefTrackerModel extends MultiTopicNTWidgetModel {
  @override
  String type = ReefTracker.widgetType;

  // Must match the topic names in GamePieceScoredTracker.java
  String get occupiedTopic => '$topic/Occupied';
  String get selectionTopic => '$topic/Operator Selection';

  late NT4Subscription occupiedSubscription;

  @override
  List<NT4Subscription> get subscriptions => [occupiedSubscription];

  ReefTrackerModel({
    required super.ntConnection,
    required super.preferences,
    required super.topic,
    super.period,
  }) : super();

  ReefTrackerModel.fromJson({
  required super.ntConnection,
  required super.preferences,
  required super.jsonData,
}) : super.fromJson();

  @override
  void initializeSubscriptions() {
    occupiedSubscription = ntConnection.subscribe(occupiedTopic, super.period);
  }

  /// Sends e.g. "L4-A" to the robot, which toggles that slot.
  void toggleSlot(int level, int branch) {
    String value = '${reefLevels[level]}-${reefBranches[branch]}';

    NT4Topic? topic = ntConnection.getTopicFromName(selectionTopic);
    if (topic == null) {
      return;
    }

    if (!ntConnection.isTopicPublished(topic)) {
      ntConnection.publishTopic(topic);
    }

    ntConnection.updateDataFromTopic(topic, value);
  }
}

/// One clickable circle on the reef.
class ReefCircle {
  final int level;
  final int branch;
  final Offset center;
  final double radius;

  const ReefCircle(this.level, this.branch, this.center, this.radius);
}

/// Shared by the painter and the tap handler so they always agree.
List<ReefCircle> layoutReef(Size size) {
  final double radius = _circleRadius * _reefRadius(size);
  final result = <ReefCircle>[];
  for (int level = 0; level < 3; level++) {
    for (int branch = 0; branch < 12; branch++) {
      result.add(
        ReefCircle(
          level,
          branch,
          _branchPoint(size, -branch, _levelDistance[level]),
          radius,
        ),
      );
    }
  }
  return result;
}

class ReefTracker extends NTWidget {
  static const String widgetType = 'Reef Tracker';

  const ReefTracker({super.key});

  @override
  Widget build(BuildContext context) {
    ReefTrackerModel model = cast(context.watch<NTWidgetModel>());

    return ListenableBuilder(
      listenable: Listenable.merge(model.subscriptions),
      builder: (context, _) {
        List<Object?> raw = tryCast(model.occupiedSubscription.value) ?? [];
        List<bool> occupied = raw.whereType<bool>().toList();

        return LayoutBuilder(
          builder: (context, constraints) {
            final Size size = Size(
              constraints.maxWidth,
              constraints.maxHeight,
            );
            final circles = layoutReef(size);

            return GestureDetector(
              onTapUp: (details) {
                ReefCircle? best;
                double bestDistance = double.infinity;
                for (final circle in circles) {
                  final double d = (details.localPosition - circle.center)
                      .distance;
                  if (d <= circle.radius * 1.2 && d < bestDistance) {
                    best = circle;
                    bestDistance = d;
                  }
                }
                if (best != null) {
                  model.toggleSlot(best.level, best.branch);
                }
              },
              child: CustomPaint(
                size: size,
                painter: ReefPainter(circles: circles, occupied: occupied),
              ),
            );
          },
        );
      },
    );
  }
}

class ReefPainter extends CustomPainter {
  final List<ReefCircle> circles;
  final List<bool> occupied;

  const ReefPainter({required this.circles, required this.occupied});

  bool _isOccupied(ReefCircle circle) {
    final int i = circle.level * 12 + circle.branch;
    return i < occupied.length && occupied[i];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final double r = _reefRadius(size);
    final Offset c = Offset(size.width / 2, size.height / 2);

    // Hexagon in the center
    final Paint hexPaint = Paint()
      ..color = Colors.lightBlueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final double hexCircumradius = _hexApothem / cos(pi / 6);
    final Path hex = Path();
    for (int k = 0; k < 6; k++) {
      final double a = (faceStartDegrees + 30 + 60.0 * k) * pi / 180;
      final Offset p = c + Offset(cos(a), sin(a)) * (hexCircumradius * r);
      if (k == 0) {
        hex.moveTo(p.dx, p.dy);
      } else {
        hex.lineTo(p.dx, p.dy);
      }
    }
    hex.close();
    canvas.drawPath(hex, hexPaint);

    // Branch letters inside the hexagon, next to each branch's column
    for (int branch = 0; branch < 12; branch++) {
      final TextPainter text = TextPainter(
        text: TextSpan(
          text: reefBranches[branch],
          style: TextStyle(
            color: Colors.white,
            fontSize: 0.1 * r,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final Offset p = _branchPoint(
        size,
        -branch,
        _hexApothem - 0.05,
        offset: 0.06,
      );
      text.paint(canvas, p - Offset(text.width / 2, text.height / 2));
    }

    // Circles (all the same size, no labels)
    for (final circle in circles) {
      final bool filled = _isOccupied(circle);

      canvas.drawCircle(
        circle.center,
        circle.radius,
        Paint()
          ..color = filled ? Colors.lightGreenAccent : Colors.white24
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        circle.center,
        circle.radius,
        Paint()
          ..color = Colors.white70
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant ReefPainter oldDelegate) {
    if (oldDelegate.occupied.length != occupied.length) return true;
    for (int i = 0; i < occupied.length; i++) {
      if (oldDelegate.occupied[i] != occupied[i]) return true;
    }
    return false;
  }
}