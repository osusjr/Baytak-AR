import 'dart:convert';
import 'dart:io';

import 'ai_client.dart';
import 'kitchen_generator.dart';

/// Sends the blueprint image to a free NVIDIA-hosted vision model and asks
/// for the kitchen layout as strict JSON, which is defensively parsed into
/// a [LayoutPlan] for the on-device generator. No keys are typed in-app -
/// see ai_client.dart / DemoConfig for how the demo key ships.
class BlueprintAnalysisException implements Exception {
  BlueprintAnalysisException(this.message);
  final String message;

  @override
  String toString() => message;
}

const _prompt = '''
You are a kitchen floor-plan reader. Analyze the attached blueprint image
and return the kitchen layout as JSON ONLY - no prose, no markdown fences.

Coordinate system: looking at the drawing, origin is the TOP-LEFT inside
corner of the room. x runs right (metres), z runs down (metres).
Walls: north = top edge, south = bottom, west = left, east = right.
Positions along north/south walls are x metres; along east/west walls are
z metres, both measured from that wall's origin end (west end for N/S,
north end for E/W).

Read printed dimensions when present (convert feet/inches to metres);
otherwise estimate from scale. Cabinet runs are the counter rectangles
against walls. Mark sink_at_m / range_at_m with the centre position of the
basin / cooktop ON that run, or null. A freestanding or peninsula counter
(bar) is the "island"; if the cooktop sits on it, set cooktop true, and
set seating to the side where stools/overhang are drawn. x_m,z_m are the
island's top-left corner.

Schema (all lengths in metres, numbers only):
{
 "width_m": 0.0,
 "depth_m": 0.0,
 "runs": [
   {"wall":"north|south|east|west","from_m":0.0,"to_m":0.0,
    "sink_at_m":null,"range_at_m":null,
    "fridge":"start|end|null","uppers":true}
 ],
 "island": {"present":false,"x_m":0.0,"z_m":0.0,"w_m":0.0,"d_m":0.0,
            "seating":"north|south|east|west","cooktop":false},
 "windows": [{"wall":"north","center_m":0.0,"width_m":0.0}],
 "palette": "warm_walnut|light_oak|dark_modern",
 "summary": "one short sentence describing the layout"
}

Choose the palette that suits the drawing's context: warm_walnut for
classic/family homes, light_oak for bright/small/modern spaces,
dark_modern for premium/contemporary.
''';

Future<LayoutPlan> analyzeBlueprint(File image) async {
  final bytes = await image.readAsBytes();
  if (bytes.length > 15 * 1024 * 1024) {
    throw BlueprintAnalysisException(
        'Image is too large for analysis - re-pick it (the app resizes '
        'gallery picks automatically).');
  }
  final ext = image.path.toLowerCase();
  final mediaType = ext.endsWith('.png') ? 'image/png' : 'image/jpeg';

  String text;
  try {
    text = await visionCall(
      imageBytes: bytes,
      mediaType: mediaType,
      prompt: _prompt,
    );
  } on AiClientException catch (e) {
    throw BlueprintAnalysisException(e.message);
  }

  try {
    final json =
        jsonDecode(extractJsonObject(text)) as Map<String, dynamic>;
    final plan = LayoutPlan.fromJson(json);
    if (plan.runs.isEmpty) {
      throw BlueprintAnalysisException(
          'The AI could not identify any cabinet runs in this drawing. '
          'Try a clearer image, or use the manual measurements below.');
    }
    return plan;
  } on BlueprintAnalysisException {
    rethrow;
  } catch (e) {
    throw BlueprintAnalysisException(
        'Could not parse the AI response as a layout.\n\n$e');
  }
}
