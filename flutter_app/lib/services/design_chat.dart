import 'dart:convert';

import 'ai_client.dart';
import 'blueprint_ai.dart' show planJsonSchema, planCoordSpec;
import 'kitchen_design.dart';
import 'kitchen_generator.dart';
import 'plan_normalizer.dart';

/// b28 AI designer chat: a multi-turn conversation that designs a kitchen
/// from the user's photos and words. The user can send
///  * a photo of their EMPTY ROOM (plus typed dimensions),
///  * photos of MATERIALS/COLOURS they like (an existing kitchen, a
///    worktop sample, a magazine page),
///  * plain requests ("darker cabinets", "move the sink under the window")
/// and every AI reply may carry a full LayoutPlan and/or a KitchenDesign,
/// which the app renders with the ON-DEVICE generator - the AI never
/// produces pixels, it produces the parametric plan; rendering is free.
///
/// Cost control: earlier photos are NOT resent on every turn (the model's
/// own textual reading of them stays in the history instead), and the
/// current plan+design travel as compact JSON state. Pure logic, no
/// Flutter imports - unit-tested in widget_test.dart.
class DesignChatReply {
  DesignChatReply({required this.reply, this.plan, this.design});

  final String reply;
  final LayoutPlan? plan;
  final KitchenDesign? design;
}

/// The finish vocabulary is GENERATED from the real option tables, so the
/// prompt can never drift from what the design system actually renders.
String designVocabulary() => '''
Design element options (use these ids EXACTLY, one per element):
 lower/upper/island cabinets: ${cabinetFinishes.keys.join('|')}
 worktop: ${worktops.keys.join('|')}
 wall: ${wallPaints.keys.join('|')}
 floor: ${floorFinishes.keys.join('|')}
 splash: ${backsplashes.keys.join('|')}
 hardware: ${hardwareFinishes.keys.join('|')}
 handle: ${handleStyles.keys.join('|')}
 door: ${doorStyles.keys.join('|')}''';

String _systemPrompt() => '''
You are the Baytak AR kitchen designer, chatting with a customer in Jordan.
You design kitchens as STRUCTURED DATA that the app renders as a 3D model
with its own catalogue textures. You cannot produce images - never claim
to; say the app will build the 3D model from your plan.

Your reply MUST be a single JSON object, nothing else:
{
 "reply": "friendly answer to the customer (short, no JSON inside)",
 "plan": <a plan object per the schema below, or null to keep the current plan>,
 "design": <a design object, or null to keep the current design>
}

The "design" object picks one option id per element, e.g.
{"lower":"navy_blue","upper":"white_satin","island":"navy_blue",
 "worktop":"white_quartz","wall":"warm_white","floor":"light_oak",
 "splash":"white_subway","hardware":"brass","handle":"bar","door":"shaker"}.
${designVocabulary()}
A partial "design" is fine: elements you leave out keep their current
values. When the customer shows a materials/colour photo, map what you
see to the CLOSEST options above and say what you matched ("your
cabinets look like navy blue with brass handles"). Do not invent option
ids.

The "plan" object uses this schema:
$planJsonSchema
$planCoordSpec

Rules:
- To design a room you need its width and depth in metres. If the
  customer has not given dimensions (typed or on a drawing), ASK for them
  in "reply" and send plan:null.
- Only include "plan" when the layout should CHANGE; only include
  "design" when finishes should change. Both null = a chat answer.
- Keep walkways ≥ 0.9 m, sink and cooker ≥ 0.95 m apart, fridge at a run
  end. The app re-validates everything you send.
- Answer in the customer's language (Arabic or English).''';

class DesignChatSession {
  DesignChatSession({this.plan, this.design});

  /// Live state: the latest plan/design the conversation produced (or was
  /// seeded with from the Design studio).
  LayoutPlan? plan;
  KitchenDesign? design;

  /// Text-only transcript sent back to the model each turn. Image turns
  /// are recorded as a note plus the model's own answer, so earlier
  /// photos never get re-uploaded (each would cost tokens every turn).
  final List<Map<String, dynamic>> history = [];
  static const _historyKeep = 10;

  bool get hasPlan => plan != null;

  /// True once the CONVERSATION produced a plan (vs. one it was merely
  /// seeded with) - the studio uses it to decide whether opening the
  /// result is a fresh generation worth snapshotting as "the original".
  bool generatedPlan = false;

  /// The plan as shown to the MODEL: internal control fields stripped.
  /// orig_a/orig_b drive the regrow pass and 'auto' drives the ghost
  /// sweep - a model echoing them back (very common LLM behaviour) would
  /// smuggle stale memory into its own edit and the normalizer would
  /// promptly "restore" bounds the model meant to change. Public for
  /// unit tests.
  static Map<String, dynamic> modelFacingPlanJson(LayoutPlan p) {
    final j = p.toJson();
    for (final r in (j['runs'] as List)) {
      (r as Map)
        ..remove('orig_a')
        ..remove('orig_b')
        ..remove('auto');
    }
    return j;
  }

  /// Sends one user turn. [imageParts] are prebuilt via [aiImagePart]
  /// (max 2 per message keeps the request under the proxy's body cap).
  Future<DesignChatReply> send(String text,
      {List<Map<String, dynamic>> imageParts = const []}) async {
    final state = StringBuffer('CURRENT STATE\n');
    state.writeln(plan == null
        ? 'plan: none yet'
        : 'plan: ${jsonEncode(modelFacingPlanJson(plan!))}');
    state.writeln(design == null
        ? 'design: app defaults'
        : 'design: ${design!.encode()}');

    final userNote =
        imageParts.isEmpty ? text : '$text\n[${imageParts.length} photo(s) attached]';
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': _systemPrompt()},
      ...history,
      {'role': 'system', 'content': state.toString()},
      if (imageParts.isEmpty)
        {'role': 'user', 'content': text}
      else
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': text},
            ...imageParts,
          ],
        },
    ];

    final raw = await chatCall(
      messages: messages,
      // image turns need the vision chain; text refinements too when the
      // conversation is seeded by photos the model described earlier -
      // GPT-5.6 serves both, and on free builds the vision chain is the
      // safer default for a designer that keeps referring back to photos
      vision: true,
    );

    final parsed = parseReply(raw, base: design);

    // remember the turn (text-only echo, never the image bytes; clipped
    // so a degraded raw model dump can never bloat every later request
    // toward the proxy's body cap)
    history
      ..add({'role': 'user', 'content': _clip(userNote)})
      ..add({'role': 'assistant', 'content': _clip(parsed.reply)});
    while (history.length > _historyKeep) {
      history.removeAt(0);
    }

    if (parsed.plan != null) {
      plan = parsed.plan;
      generatedPlan = true;
    }
    if (parsed.design != null) design = parsed.design;
    return parsed;
  }

  static String _clip(String s, [int max = 2000]) =>
      s.length <= max ? s : '${s.substring(0, max)}...';

  /// Parses the model JSON contract; a malformed answer degrades to a
  /// plain chat reply instead of an error. [base] is the session's
  /// current design: a PARTIAL design object from the model (a very
  /// common LLM shortcut - "just the cabinets changed") merges onto it
  /// instead of resetting every unmentioned element to app defaults.
  /// Public for unit tests.
  static DesignChatReply parseReply(String raw, {KitchenDesign? base}) {
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(extractJsonObject(raw)) as Map<String, dynamic>;
    } catch (_) {
      return DesignChatReply(reply: raw.trim());
    }

    LayoutPlan? plan;
    final pj = j['plan'];
    if (pj is Map<String, dynamic>) {
      // echo guard on the RAW values, like the blueprint parser - after
      // fromJson the dimensions are already clamped into [2,9] and the
      // guard could never fire
      double rawNum(dynamic v) =>
          (v is num) ? v.toDouble() : double.tryParse('$v') ?? 0;
      if (rawNum(pj['width_m']) >= 1.0 && rawNum(pj['depth_m']) >= 1.0) {
        try {
          final p = LayoutPlan.fromJson(pj);
          if (p.runs.isNotEmpty) {
            // an AI-authored bound is a deliberate edit: rebase the orig
            // memory so the regrow pass can never "restore" a layout the
            // model (or an echoed stale orig_* key) just changed
            for (final r in p.runs) {
              r.rebaseOrig();
              r.auto = false;
            }
            normalizePlan(p);
            if (p.runs.isNotEmpty) plan = p;
          }
        } catch (_) {/* keep plan null - reply still shows */}
      }
    }

    KitchenDesign? design;
    final dj = j['design'];
    if (dj is Map<String, dynamic>) {
      try {
        design = KitchenDesign.fromJson({
          if (base != null) ...base.toJson(),
          ...dj,
        });
      } catch (_) {/* defensive - fromJson already falls back per field */}
    }

    final reply = '${j['reply'] ?? ''}'.trim();
    return DesignChatReply(
      reply: reply.isEmpty
          ? (plan != null || design != null
              ? 'Here is the updated design.'
              : raw.trim())
          : reply,
      plan: plan,
      design: design,
    );
  }
}
