import 'package:latlong2/latlong.dart';

/// Returns a map polygon (meters on the ground) extending in the
/// provided compass bearing, clockwise from geographic north.
/// This is only a visualization of heading, not a navigable safe corridor.
List<LatLng> directionSector(
  LatLng origin,
  double headingDegrees, {
  double radiusMeters = 42,
  double halfAngleDegrees = 28,
  int steps = 16,
}) {
  if (!headingDegrees.isFinite || radiusMeters <= 0 || steps < 2) {
    return const <LatLng>[];
  }
  const distance = Distance();
  return [
    origin,
    for (var i = 0; i <= steps; i++)
      distance.offset(
        origin,
        radiusMeters,
        headingDegrees - halfAngleDegrees + 2 * halfAngleDegrees * i / steps,
      ),
  ];
}
