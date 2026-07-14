import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/demo_config.dart';

/// One vision call against NVIDIA's FREE hosted models (build.nvidia.com,
/// no card; rate-limited ~40 req/min - plenty for demos). v17 removed the
/// in-app provider/key pickers: the key ships with the build
/// (--dart-define=NVIDIA_API_KEY) or arrives via the Supabase demo_config
/// table; users never see or type keys.
///
/// PRODUCTION NOTE: consumer builds must not carry provider keys at all -
/// calls are proxied through the retailer's backend. Seam documented in
/// README "Going to production".

/// Tried in order. NVIDIA retires hosted model ids over time; an unknown
/// id answers 404 (plain text), so each one falls through to the next.
/// Verified live on integrate.api.nvidia.com, 2026-07.
const aiVisionModels = [
  'meta/llama-4-maverick-17b-128e-instruct', // multimodal all-rounder
  'nvidia/nemotron-nano-12b-v2-vl', // document/drawing specialist
  'mistralai/mistral-small-4-119b-2603',
  'meta/llama-3.2-90b-vision-instruct',
];

const _endpoint = 'https://integrate.api.nvidia.com/v1/chat/completions';

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
Future<String> _resolveKey() async {
  if (DemoConfig.nvidiaApiKey.isNotEmpty) return DemoConfig.nvidiaApiKey;
  try {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString('cfg_nvidia_key') ?? '').trim();
  } catch (_) {
    return '';
  }
}

/// Whether AI features can run on this build (key present).
Future<bool> aiConfigured() async => (await _resolveKey()).isNotEmpty;

const aiNotConfiguredMessage =
    'AI analysis is not configured on this build. Add a free key from '
    'build.nvidia.com either at build time '
    '(--dart-define=NVIDIA_API_KEY=nvapi-...) or in the Supabase '
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
  final key = await _resolveKey();
  if (key.isEmpty) throw AiClientException(aiNotConfiguredMessage);

  final (prepared, mime) = await _prepareImage(imageBytes, mediaType);
  final dataUri = 'data:$mime;base64,${base64Encode(prepared)}';

  final headers = {
    'content-type': 'application/json',
    'accept': 'application/json',
    'authorization': 'Bearer $key',
  };

  Future<http.Response> post(String body) async {
    try {
      return await http
          .post(Uri.parse(_endpoint), headers: headers, body: body)
          .timeout(const Duration(seconds: 90));
    } on Exception catch (e) {
      throw AiClientException(
          'Could not reach the NVIDIA API - check the internet '
          'connection.\n\n$e');
    }
  }

  http.Response? resp;
  for (final model in aiVisionModels) {
    final body = jsonEncode({
      'model': model,
      'max_tokens': maxTokens,
      'temperature': 0.2,
      'messages': [
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
    });
    resp = await post(body);
    // Unknown/retired model ids answer 404 (routing happens before auth);
    // anything else - success or a real error - stops the fallback chain.
    if (resp.statusCode != 404) break;
  }
  resp!;

  if (resp.statusCode == 404) {
    throw AiClientException(
        'None of the free NVIDIA vision models responded (tried: '
        '${aiVisionModels.join(', ')}). The hosted catalogue may have '
        'rotated - update aiVisionModels in ai_client.dart.');
  }
  if (resp.statusCode == 401 || resp.statusCode == 403) {
    throw AiClientException(
        'The NVIDIA API rejected the demo key (${resp.statusCode}). '
        'Regenerate a free key at build.nvidia.com and update the build '
        'or the Supabase demo_config row.');
  }
  if (resp.statusCode == 429) {
    throw AiClientException(
        'Free-tier rate limit reached (~40 analyses/min). Wait a moment '
        'and try again.');
  }
  if (resp.statusCode != 200) {
    // error bodies are not always JSON (or present) - show an excerpt
    final excerpt =
        resp.body.length > 400 ? resp.body.substring(0, 400) : resp.body;
    throw AiClientException(
        'NVIDIA API error ${resp.statusCode}:\n$excerpt');
  }

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
    final text = content is String
        ? content
        : content is List
            ? content
                .map((p) =>
                    p is Map && p['text'] != null ? '${p['text']}' : '')
                .join()
            : '';
    if (text.trim().isEmpty) {
      throw AiClientException(
          'The model returned an empty answer - try again.');
    }
    return text;
  } on AiClientException {
    rethrow;
  } catch (e) {
    throw AiClientException('Could not read the API response.\n\n$e');
  }
}
