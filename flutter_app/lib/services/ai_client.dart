import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/demo_config.dart';
import 'device_id.dart';

/// One vision call against NVIDIA's FREE hosted models (build.nvidia.com,
/// no card; rate-limited ~40 req/min - plenty for demos). v17 removed the
/// in-app provider/key pickers: the key ships with the build
/// (--dart-define=NVIDIA_API_KEY) or arrives via the Supabase demo_config
/// table; users never see or type keys.
///
/// PRODUCTION NOTE: consumer builds must not carry provider keys at all -
/// calls are proxied through the retailer's backend. Seam documented in
/// README "Going to production".

/// NVIDIA-hosted models, tried in order. Ranked by a REAL benchmark
/// (tools/bench/, 2026-07: three distinct blueprints scored against ground
/// truth): qwen3.5-397b read all three perfectly (100/100/100),
/// nemotron-12b-vl averaged 83, llama-3.2-90b averaged 79. Excluded:
/// mistral-small-4 (drew runs on all four walls of EVERY drawing - the
/// exact same-kitchen-every-time bug), and llama-4-maverick/nemotron-omni/
/// qwen-122b/gemma-4 (hung on every call). Unknown ids answer 404 and hung
/// models time out - both fall through to the next candidate.
const aiVisionModels = [
  'qwen/qwen3.5-397b-a17b', // benchmark winner - perfect layout reads
  'nvidia/nemotron-nano-12b-v2-vl', // fast document specialist, avg 83
  'meta/llama-3.2-90b-vision-instruct', // avg 79, distinct layouts
];

/// Optional second free provider: Gemini Flash through Google's
/// OpenAI-compatible endpoint (same request shape). Used when a
/// GEMINI_API_KEY is configured - an independent fallback if NVIDIA's
/// free tier has a bad day.
const aiGeminiModels = [
  'gemini-3.5-flash',
  'gemini-2.5-flash',
];

/// TEXT reasoning models for stage 2 of the two-stage blueprint pipeline
/// (vision model describes the drawing, one of these turns the
/// description into the strict plan JSON). Benchmark-ranked on the same
/// four ground-truth blueprints (tools/bench/bench_two_stage.py):
/// mistral-large-3 and deepseek-v4-pro both converted every description
/// without a failure (avg 90.9); mistral is ~3x faster (7-22 s).
const aiTextModels = [
  'mistralai/mistral-large-3-675b-instruct-2512', // fast + zero failures
  'deepseek-ai/deepseek-v4-pro', // equally reliable, slower
  'nvidia/nemotron-3-super-120b-a12b', // strong when it answers
];

const _nvidiaEndpoint =
    'https://integrate.api.nvidia.com/v1/chat/completions';
const _geminiEndpoint =
    'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions';

/// Optional PAID provider: OpenAI pay-as-you-go (no subscription). When an
/// OPENAI_API_KEY is configured, GPT-5.6 (both vision and reasoning in one
/// model) goes FIRST in both chains; free models remain as fallback so a
/// spent credit balance can never kill a demo. GPT-5.x quirks handled in
/// _chatCall: max_completion_tokens instead of max_tokens, and no
/// temperature override (reasoning models reject non-default values).
const _openaiEndpoint = 'https://api.openai.com/v1/chat/completions';

class _Candidate {
  const _Candidate(this.endpoint, this.key, this.model);
  final String endpoint, key, model;
}

/// Inline data-URI images must stay under ~180 KB (NVIDIA rule; larger
/// needs their assets API). Base64 inflates ~33%, so raw JPEG <= 130 KB.
const _imageBudgetBytes = 130 * 1024;

class AiClientException implements Exception {
  AiClientException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Key resolution: build-time define first, then the key cached from the
/// Supabase demo_config table (written by RemoteCatalog.sync).
///
/// Values are SANITIZED: a key or URL that picked up a newline, tab or
/// stray space (a wrapped --dart-define paste, a copied cell, an editor
/// that hard-wraps) would otherwise build an illegal HTTP header and fail
/// every single call with an unactionable FormatException. Observed live
/// on a Windows build where the anon key paste broke across lines.
String sanitizeConfigValue(String v) => v.replaceAll(RegExp(r'\s+'), '');
String _sanitize(String v) => sanitizeConfigValue(v);

Future<String> _resolveKey(String define, String prefsKey) async {
  final d = _sanitize(define);
  if (d.isNotEmpty) return d;
  try {
    final prefs = await SharedPreferences.getInstance();
    return _sanitize(prefs.getString(prefsKey) ?? '');
  } catch (_) {
    return '';
  }
}

/// The Supabase anon key as sent to the proxy (whitespace-stripped).
String get _anonKey => _sanitize(DemoConfig.supabaseAnonKey);

/// Production proxy URL: dart-define first, else the demo_config row
/// cached by RemoteCatalog ('cfg_ai_proxy'). When set, every candidate
/// call travels through the store's Edge Function and NO provider key is
/// needed (or present) in the app.
Future<String> _proxyUrl() =>
    _resolveKey(DemoConfig.aiProxyUrl, 'cfg_ai_proxy');

Future<List<_Candidate>> _candidates({bool text = false}) async {
  final nvidiaModels = text ? aiTextModels : aiVisionModels;
  final proxy = await _proxyUrl();
  if (proxy.isNotEmpty && _anonKey.isNotEmpty) {
    // launch mode: full chain via the proxy, authenticated with the
    // Supabase anon key (the gateway requires a valid JWT). The proxy
    // rejects any model it cannot serve (400/501) and those fall through,
    // and it only charges quota for BILLED calls, so listing the full
    // chain costs nothing extra.
    return [
      _Candidate(proxy, _anonKey, _sanitize(DemoConfig.openaiModel)),
      for (final m in nvidiaModels) _Candidate(proxy, _anonKey, m),
      for (final m in aiGeminiModels) _Candidate(proxy, _anonKey, m),
    ];
  }

  final openai =
      await _resolveKey(DemoConfig.openaiApiKey, 'cfg_openai_key');
  final nvidia =
      await _resolveKey(DemoConfig.nvidiaApiKey, 'cfg_nvidia_key');
  final gemini =
      await _resolveKey(DemoConfig.geminiApiKey, 'cfg_gemini_key');
  return [
    // paid quality first when configured (GPT-5.6 is multimodal - the
    // same model serves the vision AND the reasoning chain)
    if (openai.isNotEmpty)
      _Candidate(_openaiEndpoint, openai, _sanitize(DemoConfig.openaiModel)),
    if (nvidia.isNotEmpty)
      for (final m in nvidiaModels) _Candidate(_nvidiaEndpoint, nvidia, m),
    // Gemini Flash handles both modalities - same chain either way
    if (gemini.isNotEmpty)
      for (final m in aiGeminiModels) _Candidate(_geminiEndpoint, gemini, m),
  ];
}

/// Whether AI features can run on this build (any provider key present).
Future<bool> aiConfigured() async => (await _candidates()).isNotEmpty;

/// Human-readable name of the provider that will answer FIRST, for the
/// screens' captions ("Runs on ..."). Never hardcode a provider name in
/// UI text - builds differ.
Future<String> aiProviderLabel() async {
  final c = await _candidates();
  if (c.isEmpty) return 'no AI configured';
  return _friendlyModel(c.first.model, c.first.endpoint);
}

/// The model that actually produced the last successful answer, e.g.
/// "GPT-5.6 Sol (OpenAI)" - shown after each analysis so nobody has to
/// guess which provider served it (and whether the paid key worked).
String? aiLastAnsweredBy;

String _friendlyModel(String model, String endpoint) {
  if (model.startsWith('gpt-')) {
    final tier = model.replaceFirst('gpt-', 'GPT-').split('-').map((p) {
      return p.isEmpty ? p : '${p[0].toUpperCase()}${p.substring(1)}';
    }).join(' ');
    final via = endpoint == _openaiEndpoint ? 'OpenAI, paid' : 'store proxy';
    return '$tier ($via)';
  }
  if (model.startsWith('gemini-')) {
    return '$model (${endpoint == _geminiEndpoint ? 'Google' : 'store proxy'})';
  }
  final short = model.split('/').last;
  final via = endpoint == _nvidiaEndpoint ? 'NVIDIA, free' : 'store proxy';
  return '$short ($via)';
}

const aiNotConfiguredMessage =
    'AI analysis is not configured on this build. Add a key at build time '
    '(--dart-define=OPENAI_API_KEY=... for paid GPT-5.6, or a free '
    'NVIDIA_API_KEY=... / GEMINI_API_KEY=...) or in the Supabase '
    'demo_config table - see the README. Manual measurements below work '
    'offline.';

// ---------------------------------------------------------------------------
// image preparation: decode -> downscale -> JPEG until under budget.
// Runs in a background isolate (S9+ decodes multi-MP photos in ~a second).
// ---------------------------------------------------------------------------
Uint8List _shrinkForAi(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw AiClientException(
        'Could not read that image - pick a JPG or PNG photo.');
  }
  Uint8List best = bytes;
  for (final step in const [
    [1600, 80],
    [1280, 72],
    [1024, 64],
    [900, 56],
    [768, 50],
    [640, 45],
  ]) {
    final maxDim = step[0], quality = step[1];
    var frame = decoded;
    if (decoded.width > maxDim || decoded.height > maxDim) {
      frame = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: maxDim)
          : img.copyResize(decoded, height: maxDim);
    }
    best = Uint8List.fromList(img.encodeJpg(frame, quality: quality));
    if (best.length <= _imageBudgetBytes) return best;
  }
  return best; // smallest attempt - still send it, the API may accept
}

Future<(Uint8List, String)> _prepareImage(
    List<int> imageBytes, String mediaType) async {
  final raw = Uint8List.fromList(imageBytes);
  if (raw.length <= _imageBudgetBytes) {
    // Trust the bytes, not the file extension (the picker screens rename
    // every pick to .jpg regardless of the real format).
    if (raw.length > 3 &&
        raw[0] == 0xFF &&
        raw[1] == 0xD8 &&
        raw[2] == 0xFF) {
      return (raw, 'image/jpeg');
    }
    if (raw.length > 4 &&
        raw[0] == 0x89 &&
        raw[1] == 0x50 &&
        raw[2] == 0x4E &&
        raw[3] == 0x47) {
      return (raw, 'image/png');
    }
    // unknown container (webp/heic/...) -> re-encode below
  }
  final shrunk = await compute(_shrinkForAi, raw);
  return (shrunk, 'image/jpeg');
}

// ---------------------------------------------------------------------------
// response text cleanup shared by the blueprint/room parsers
// ---------------------------------------------------------------------------
/// Drops reasoning traces and markdown fences, then isolates the first
/// balanced {...} JSON object - free hosted models vary in chattiness.
String extractJsonObject(String text) {
  var t = text.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
  if (t.startsWith('```')) {
    t = t
        .replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '')
        .replaceFirst(RegExp(r'```\s*$'), '')
        .trim();
  }
  final start = t.indexOf('{');
  if (start < 0) return t;
  var depth = 0;
  var inString = false;
  for (var i = start; i < t.length; i++) {
    final c = t[i];
    if (inString) {
      if (c == r'\') {
        i++; // skip escaped char
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return t.substring(start, i + 1);
    }
  }
  return t.substring(start);
}

// ---------------------------------------------------------------------------
Future<String> visionCall({
  required List<int> imageBytes,
  required String mediaType,
  required String prompt,
  int maxTokens = 4096,
}) async {
  final candidates = await _candidates();
  if (candidates.isEmpty) throw AiClientException(aiNotConfiguredMessage);

  final (prepared, mime) = await _prepareImage(imageBytes, mediaType);
  final dataUri = 'data:$mime;base64,${base64Encode(prepared)}';
  return _chatCall(
    candidates,
    (model) => [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': prompt},
          {
            'type': 'image_url',
            'image_url': {'url': dataUri},
          },
        ],
      }
    ],
    maxTokens: maxTokens,
  );
}

/// b28 multi-turn chat: pass a prebuilt OpenAI-style messages list
/// (system/user/assistant; content is a string or a parts list carrying
/// inline data-URI images from [aiImagePart]). Uses the vision chain when
/// [vision] so an image-bearing turn reaches a model that can see; text
/// refinement turns can run the (cheaper, benchmark-ranked) text chain.
/// Same candidate fallback behaviour as [visionCall].
Future<String> chatCall({
  required List<Map<String, dynamic>> messages,
  bool vision = true,
  int maxTokens = 8192,
}) async {
  final candidates = await _candidates(text: !vision);
  if (candidates.isEmpty) throw AiClientException(aiNotConfiguredMessage);
  return _chatCall(candidates, (_) => messages, maxTokens: maxTokens);
}

/// Prepares a picked photo as an inline image_url part for [chatCall]:
/// downscaled/re-encoded to the provider budget in a background isolate -
/// the exact same path [visionCall] uses.
Future<Map<String, dynamic>> aiImagePart(List<int> bytes) async {
  final (prepared, mime) = await _prepareImage(bytes, 'image/jpeg');
  return {
    'type': 'image_url',
    'image_url': {'url': 'data:$mime;base64,${base64Encode(prepared)}'},
  };
}

/// Text-only call against the reasoning chain (stage 2 of the blueprint
/// pipeline). Same fallback behaviour as [visionCall].
Future<String> textCall({
  required String prompt,
  int maxTokens = 8192,
}) async {
  final candidates = await _candidates(text: true);
  if (candidates.isEmpty) throw AiClientException(aiNotConfiguredMessage);
  return _chatCall(
    candidates,
    (model) => [
      {'role': 'user', 'content': prompt}
    ],
    maxTokens: maxTokens,
  );
}

Future<String> _chatCall(
  List<_Candidate> candidates,
  List<Map<String, dynamic>> Function(String model) messagesFor, {
  required int maxTokens,
}) async {
  final proxy = await _proxyUrl();
  final device = proxy.isEmpty ? '' : await deviceId();
  // Every failure mode falls through to the next candidate: retired ids
  // (404), hung free-tier models (timeout - observed live), rate limits,
  // even a revoked key when a second provider is configured. Stop trying
  // once the total budget is spent so the UI never waits forever.
  http.Response? ok;
  _Candidate? okBy;
  http.Response? lastResp;
  _Candidate? lastCand;
  Object? lastError;
  final clock = Stopwatch()..start();
  for (final c in candidates) {
    if (clock.elapsed > const Duration(seconds: 150)) break;
    final viaProxy = c.endpoint == proxy && proxy.isNotEmpty;
    // param quirks apply to GPT-5.x on EITHER path - the model prefix on
    // the proxy path, and the OpenAI endpoint on the direct path (guards
    // a non-gpt OPENAI_MODEL value too)
    final openai = c.model.startsWith('gpt-') || c.endpoint == _openaiEndpoint;
    // reasoning models think before answering - give them headroom
    final budget =
        c.model.startsWith('qwen/') || c.model.startsWith('deepseek')
            ? 8192
            : maxTokens;
    final body = jsonEncode({
      'model': c.model,
      // GPT-5.x rejects max_tokens and non-default temperature
      if (openai) 'max_completion_tokens': 16384 else 'max_tokens': budget,
      if (!openai) 'temperature': 0.2,
      'messages': messagesFor(c.model),
    });
    http.Response attempt;
    try {
      // GPT-5.6 reasons before answering: a hard drawing can exceed the
      // free-tier 60 s budget, so the paid candidate gets extra time
      attempt = await http.post(
        Uri.parse(c.endpoint),
        headers: {
          'content-type': 'application/json',
          'accept': 'application/json',
          'authorization': 'Bearer ${c.key}',
          if (viaProxy) 'apikey': c.key,
          if (viaProxy && _sanitize(DemoConfig.licenseKey).isNotEmpty)
            'x-license-key': _sanitize(DemoConfig.licenseKey),
          if (viaProxy) 'x-device-id': device,
        },
        body: body,
      ).timeout(Duration(seconds: (openai ? 100 : 60) + (viaProxy ? 15 : 0)));
    } on Exception catch (e) {
      lastCand = c;
      lastError = e;
      continue;
    }
    if (viaProxy && (attempt.statusCode == 402 || attempt.statusCode == 429)) {
      // license/quota problems come from OUR proxy and every candidate
      // hits the same proxy - no fallback can fix them, so stop early
      // with the proxy's own (JSON) message instead of trying 5 more.
      String msg;
      try {
        msg = '${(jsonDecode(attempt.body) as Map)['message'] ?? ''}';
      } catch (_) {
        msg = '';
      }
      throw AiClientException(msg.isNotEmpty
          ? msg
          : attempt.statusCode == 402
              ? 'The store license is missing or deactivated. Contact '
                  'Baytak support to activate this installation.'
              : 'The daily AI limit has been reached. Try again tomorrow.');
    }
    if (attempt.statusCode == 200) {
      ok = attempt;
      okBy = c;
      break;
    }
    lastResp = attempt;
    lastCand = c;
    final excerpt = attempt.body.length > 200
        ? attempt.body.substring(0, 200)
        : attempt.body;
    lastError = 'HTTP ${attempt.statusCode} from ${c.model}: $excerpt';
  }

  if (ok == null) {
    // name the provider that ACTUALLY failed - a misleading "regenerate
    // your NVIDIA key" after an OpenAI failure cost a debugging session
    final status = lastResp?.statusCode;
    final who = lastCand == null
        ? 'the AI provider'
        : _friendlyModel(lastCand.model, lastCand.endpoint);
    final console = lastCand?.endpoint == _openaiEndpoint
        ? 'platform.openai.com'
        : lastCand?.endpoint == _geminiEndpoint
            ? 'aistudio.google.com'
            : 'build.nvidia.com';
    if (status == 401 || status == 403) {
      throw AiClientException(
          '$who rejected its key ($status). Check the key at $console and '
          'update the build (--dart-define) or the Supabase demo_config '
          'row.');
    }
    if (status == 429) {
      throw AiClientException(
          '$who hit its rate limit. Wait a minute and try again.');
    }
    throw AiClientException(
        'No configured AI model answered (tried '
        '${candidates.map((c) => c.model).join(', ')}). They may be busy, '
        'or the internet connection is down. Try again in a moment.\n\n'
        'Last error from $who: $lastError');
  }
  final resp = ok;

  try {
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw AiClientException(
          'The model returned no answer - try a clearer photo.');
    }
    final first = choices.first as Map;
    if ('${first['finish_reason'] ?? ''}' == 'length') {
      throw AiClientException(
          'The model ran out of output space before finishing its answer - '
          'try again (a fresh run usually completes).');
    }
    final message = first['message'] as Map;
    final content = message['content'];
    // content is a plain string on this API; tolerate part-lists anyway
    var text = content is String
        ? content
        : content is List
            ? content
                .map((p) =>
                    p is Map && p['text'] != null ? '${p['text']}' : '')
                .join()
            : '';
    if (text.trim().isEmpty) {
      // some reasoning models answer in reasoning_content instead
      text = '${message['reasoning_content'] ?? ''}';
    }
    if (text.trim().isEmpty) {
      throw AiClientException(
          'The model returned an empty answer - try again.');
    }
    if (okBy != null) {
      aiLastAnsweredBy = _friendlyModel(okBy.model, okBy.endpoint);
    }
    return text;
  } on AiClientException {
    rethrow;
  } catch (e) {
    throw AiClientException('Could not read the API response.\n\n$e');
  }
}
