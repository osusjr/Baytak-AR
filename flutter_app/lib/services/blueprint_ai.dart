import 'dart:convert';
import 'dart:io';

import 'ai_client.dart';
import 'kitchen_generator.dart';
import 'plan_normalizer.dart';

/// Blueprint -> LayoutPlan, b20: a TWO-STAGE pipeline.
///
///  stage 1 (vision): the benchmark-best vision model writes an exhaustive
///     measured description of the drawing - no schema in sight, so it
///     reports what it sees instead of pattern-matching an example;
///  stage 2 (reasoning): a text model converts that description into the
///     strict plan JSON, applying kitchen sanity rules (open edges are not
///     walls, peninsulas are the island object, walkways stay clear).
///
/// If either stage fails the classic single-call path runs as fallback,
/// and every parsed plan goes through normalizePlan() so even a bad read
/// can never produce overlapping cabinets or a room-filling island (the
/// "counter covered the whole middle" bug). No keys are typed in-app -
/// see ai_client.dart / DemoConfig for how the demo key ships.
class BlueprintAnalysisException implements Exception {
  BlueprintAnalysisException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Disambiguation lines shared by every prompt - each one guards against
/// a misread observed on the bench U-shape blueprint (tools/bench/).
const _senses = '''
Distinguish carefully:
- A TALL or PANTRY unit is NOT a fridge. Only report a fridge where the
  drawing marks REF/FRIDGE or draws the dashed appliance box.
- A counter attached to a run or wall but extending into the room (bar,
  peninsula) is NEVER a wall run - it is the "island" object. Runs hug
  walls only.
- Edges drawn dashed/open are openings to other rooms - NOT walls; never
  put a run or window on them.
- w_m is always the x-extent (left-right on the drawing) and d_m the
  z-extent (top-bottom), for the room AND for the island.''';

const _describePrompt = '''
You are a meticulous architectural surveyor. Describe this kitchen floor
plan drawing exhaustively and precisely, in metres. Do NOT design or
improve anything - report only what is actually drawn.

Cover, with measurements:
1. Overall room width (left-right) and depth (top-bottom). Use the printed
   dimension arrows verbatim; convert feet/inches to metres.
2. Each edge of the room (top/bottom/left/right): solid wall, or
   dashed/open (dashed means open to another space - NOT a wall).
3. Every counter/cabinet run: which edge it sits against, where it starts
   and ends measured from the top-left inside corner of the room, and its
   depth. Note tall/pantry units separately - they are NOT appliances.
4. Every appliance symbol: sink basins, cooktop (circles = burners),
   fridge (box marked REF, often dashed), oven. For each: which counter it
   is on and the centre position in metres.
5. Any freestanding or attached counter (island / peninsula / bar): the
   exact rectangle (top-left corner position, then width = left-right
   extent, depth = top-bottom extent), whether it is attached to a wall or
   a run, which side stools/overhang are drawn on, and whether the cooktop
   is on it.
6. Windows and door openings: which wall, centre position, width.
7. Any printed text, labels or clearance notes, verbatim.
8. Walkway widths between counters where the drawing shows them.

Write a numbered list. Numbers in metres with two decimals.
''';

const _schema = '''
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
}''';

const _coords = '''
Coordinate system: origin is the TOP-LEFT inside corner of the room.
x runs right (metres), z runs down (metres). Walls: north = top edge,
south = bottom, west = left, east = right. Positions along north/south
walls are x metres; along east/west walls are z metres, both measured
from that wall's origin end (west end for N/S, north end for E/W).
The fridge is "start" when it sits at the run's origin end, "end"
otherwise. x_m,z_m are the island's top-left corner.''';

const _planPrompt = '''
You are a kitchen layout planner. Below is a surveyor's description of a
kitchen floor-plan drawing. Convert it into the JSON schema at the end.
Return JSON ONLY - no prose, no markdown fences.

Rules:
- Use the surveyor's measurements. Never invent runs, appliances or walls
  the surveyor did not report.
$_senses
- Sanity-check before answering: counters are ~0.6 m deep; people need
  at least 0.9 m of walkway between facing counters and around islands;
  the island rectangle must not overlap any run. Prefer the printed
  clearances the surveyor quoted.

$_coords

$_schema

Choose the palette that suits the description: warm_walnut for
classic/family homes, light_oak for bright/small/modern spaces,
dark_modern for premium/contemporary.

Surveyor's description:
''';

/// Single-call fallback prompt (the b19 path, kept prompt-hardened).
const _singlePrompt = '''
You are a kitchen floor-plan reader. Analyze the attached blueprint image
and return the kitchen layout as JSON ONLY - no prose, no markdown fences.

IMPORTANT: measure THIS drawing. Kitchens vary a lot - galley (two facing
runs), single wall, L-shape, U-shape, with or without an island. Report
only what is actually drawn; never copy the example numbers from the
schema, and never invent appliances or runs that are not in the image.
$_senses

$_coords

Use the printed dimension labels verbatim when present (convert
feet/inches to metres); otherwise estimate from scale. Cabinet runs are
the counter rectangles against walls. Mark sink_at_m / range_at_m with the
centre position of the basin / cooktop symbol ON that run, or null. If the
cooktop sits on the island, set cooktop true, and set seating to the side
where stools/overhang are drawn.

$_schema

Before answering, double-check: do your width_m/depth_m match the printed
dimension arrows? Is every run on the wall where the drawing shows
cabinets? Choose the palette that suits the drawing's context:
warm_walnut for classic/family homes, light_oak for bright/small/modern
spaces, dark_modern for premium/contemporary.
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

  // ---- two-stage: describe (vision) -> plan (reasoning) -----------------
  try {
    final description = await visionCall(
      imageBytes: bytes,
      mediaType: mediaType,
      prompt: _describePrompt,
      maxTokens: 8192,
    );
    if (description.trim().length >= 200) {
      final text = await textCall(prompt: _planPrompt + description);
      return _parsePlan(text);
    }
  } on Exception {
    // fall through to the single-call path below
  }

  // ---- fallback: classic single vision call ------------------------------
  String text;
  try {
    text = await visionCall(
      imageBytes: bytes,
      mediaType: mediaType,
      prompt: _singlePrompt,
    );
  } on AiClientException catch (e) {
    throw BlueprintAnalysisException(e.message);
  }
  return _parsePlan(text);
}

LayoutPlan _parsePlan(String text) {
  try {
    final json =
        jsonDecode(extractJsonObject(text)) as Map<String, dynamic>;
    // Echo guard: a model that ignored the image tends to return the
    // schema's example values. Reject those instead of clamping them into
    // a plausible-looking default kitchen (the v18 "every blueprint gives
    // the same model" failure).
    double numOf(dynamic v) =>
        (v is num) ? v.toDouble() : double.tryParse('$v') ?? 0;
    if (numOf(json['width_m']) < 1.0 || numOf(json['depth_m']) < 1.0) {
      throw BlueprintAnalysisException(
          'The AI answered without real measurements for this drawing. '
          'Try again, or use a sharper photo where the dimension labels '
          'are readable.');
    }
    final plan = LayoutPlan.fromJson(json);
    if (plan.runs.isEmpty) {
      throw BlueprintAnalysisException(
          'The AI could not identify any cabinet runs in this drawing. '
          'Try a clearer image, or use the manual measurements below.');
    }
    // make the plan buildable: corner overlaps trimmed, islands that
    // would block the walkways shrunk or dropped
    normalizePlan(plan);
    if (plan.runs.isEmpty) {
      throw BlueprintAnalysisException(
          'The AI read a layout that cannot be built (cabinets on top of '
          'each other). Try again with a sharper image.');
    }
    return plan;
  } on BlueprintAnalysisException {
    rethrow;
  } catch (e) {
    throw BlueprintAnalysisException(
        'Could not parse the AI response as a layout.\n\n$e');
  }
}
