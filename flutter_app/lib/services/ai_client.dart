import 'dart:convert';

import 'package:http/http.dart' as http;

/// One vision call, two providers:
///  - [AiProvider.gemini]: Google AI Studio key (aistudio.google.com) -
///    FREE tier, no card; rate-limited (fine for demos).
///  - [AiProvider.anthropic]: console.anthropic.com key - paid,
///    production quality.
/// Both take an image + prompt and return the model's text. Keys are the
/// user's own, stored on-device; production apps proxy through a backend.
enum AiProvider {
  gemini('Gemini - free'),
  anthropic('Anthropic - paid');

  const AiProvider(this.label);
  final String label;
}

class AiClientException implements Exception {
  AiClientException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Tried in order; Google retires model IDs per account generation, so a
/// 404 "no longer available" falls through to the next.
const _geminiModels = [
  'gemini-3.5-flash',
  'gemini-3-flash',
  'gemini-2.5-flash',
];
const _anthropicModel = 'claude-sonnet-4-6';

Future<String> visionCall({
  required AiProvider provider,
  required String apiKey,
  required List<int> imageBytes,
  required String mediaType,
  required String prompt,
  int maxTokens = 1200,
}) async {
  final b64 = base64Encode(imageBytes);

  Future<http.Response> post(
      Uri url, Map<String, String> headers, String body) async {
    try {
      return await http
          .post(url, headers: headers, body: body)
          .timeout(const Duration(seconds: 90));
    } on Exception catch (e) {
      throw AiClientException(
          'Could not reach the analysis API - check the internet '
          'connection.\n\n$e');
    }
  }

  http.Response resp;
  if (provider == AiProvider.gemini) {
    final headers = {
      'content-type': 'application/json',
      'x-goog-api-key': apiKey,
    };
    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {
              'inline_data': {'mime_type': mediaType, 'data': b64}
            },
            {'text': prompt},
          ],
        }
      ],
      'generationConfig': {
        'maxOutputTokens': 8192, 'responseMimeType': 'application/json',
        'temperature': 0.2,
      },
    });
    http.Response? attempt;
    for (final model in _geminiModels) {
      attempt = await post(
          Uri.parse(
              'https://generativelanguage.googleapis.com/v1beta/models/'
              '$model:generateContent'),
          headers,
          body);
      final retired = attempt.statusCode == 404 &&
          (attempt.body.contains('NOT_FOUND') ||
              attempt.body.contains('not available') ||
              attempt.body.contains('not found'));
      if (!retired) break; // success or a non-model error: stop here
    }
    resp = attempt!;
    if (resp.statusCode == 404) {
      throw AiClientException(
          'None of the Gemini models responded on this account '
          '(tried: ${_geminiModels.join(', ')}). Check which models your '
          'key can use at aistudio.google.com.');
    }
  } else {
    resp = await post(
        Uri.parse('https://api.anthropic.com/v1/messages'),
        {
          'content-type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
        jsonEncode({
          'model': _anthropicModel,
          'max_tokens': maxTokens,
          'messages': [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'image',
                  'source': {
                    'type': 'base64',
                    'media_type': mediaType,
                    'data': b64,
                  },
                },
                {'type': 'text', 'text': prompt},
              ],
            }
          ],
        }));
  }

  if (resp.statusCode == 401 ||
      resp.statusCode == 403 ||
      (resp.statusCode == 400 && resp.body.contains('API_KEY'))) {
    throw AiClientException(provider == AiProvider.gemini
        ? 'The API rejected the key. Re-check it in AI setup - free keys '
            'come from aistudio.google.com.'
        : 'The API rejected the key (401). Re-check it in AI setup - keys '
            'come from console.anthropic.com.');
  }
  if (resp.statusCode == 429) {
    throw AiClientException(provider == AiProvider.gemini
        ? 'Free-tier rate limit reached. Wait a minute and try again '
            '(the free tier allows a handful of analyses per minute).'
        : 'Rate limit reached - wait a moment and try again.');
  }
  if (resp.statusCode != 200) {
    final excerpt =
        resp.body.length > 400 ? resp.body.substring(0, 400) : resp.body;
    throw AiClientException(
        'Analysis API error ${resp.statusCode}:\n$excerpt');
  }

  try {
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    String text;
    if (provider == AiProvider.gemini) {
      final candidates = data['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) {
        throw AiClientException(
            'The model returned no answer (the image may have been '
            'blocked) - try a different photo.');
      }
      final parts =
          ((candidates.first as Map)['content'] as Map)['parts'] as List;
      text = parts
          .map((p) => p is Map && p['text'] != null ? '${p['text']}' : '')
          .join();
    } else {
      final content = data['content'] as List;
      text = content
          .map((c) => c is Map && c['type'] == 'text' ? '${c['text']}' : '')
          .join();
    }
    if (text.trim().isEmpty) {
      throw AiClientException('The model returned an empty answer - '
          'try again.');
    }
    return text;
  } on AiClientException {
    rethrow;
  } catch (e) {
    throw AiClientException(
        'Could not read the API response.\n\n$e');
  }
}
