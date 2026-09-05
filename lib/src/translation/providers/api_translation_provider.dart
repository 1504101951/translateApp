import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../settings/service_config.dart';
import '../model_result.dart';
import '../paragraph_translation.dart';
import '../translation_types.dart';

/// 配置型翻译服务；每个请求独占连接，沿用 Selection Session 的流取消语义。
class ApiTranslationProvider implements TranslationProvider {
  ApiTranslationProvider({required this.config, required this.credentials});
  final ServiceConfig config;
  final Future<Map<String, String>> Function() credentials;
  @override
  String get id => config.id;

  /// request 为同一会话的原文与语言方向；返回增量译文及完整结束/失败事件。
  @override
  Stream<TranslationEvent> translate(TranslationRequest request) {
    // 语义模型需要整篇上下文；其他服务按原文段落建立可验证的一一对应。
    return translateParagraphs(
      _translate,
      request,
      keepWholeSource: config.isModel && config.semanticPairs,
    );
  }

  /// request 为一次服务请求的文本与方向；返回协议解析后的事件流，取消时关闭连接。
  Stream<TranslationEvent> _translate(TranslationRequest request) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final output = StreamController<TranslationEvent>();
    var active = true;

    /// event 为业务事件；取消后不再发布迟到结果，无返回值。
    void emit(TranslationEvent event) {
      if (active && !output.isClosed) output.add(event);
    }

    /// 无参数；读取内存凭据后执行单次协议请求，结束时发布完成事件。
    Future<void> run() async {
      config.validate();
      final secret = await credentials();
      if (!active) return;
      config.validateCredentials(secret);
      final base = config.baseUrl.replaceFirst(RegExp(r'/+$'), '');
      final path = switch (config.kind) {
        'baidu' => '/api/trans/vip/translate',
        'google' => '/language/translate/v2',
        'openai' || 'deepseek' => '/chat/completions',
        'anthropic' => '/messages',
        _ => throw const _ApiFailure('不支持的翻译服务。'),
      };
      final http = await client.postUrl(Uri.parse('$base$path'));
      if (!active) return;
      // 不随重定向把凭据或原文发送到另一个地址。
      http.followRedirects = false;
      Object body;
      if (config.kind == 'baidu') {
        const languageCodes = {
          'zh-CN': 'zh',
          'zh-TW': 'cht',
          'ja': 'jp',
          'ko': 'kor',
          'fr': 'fra',
          'es': 'spa',
          'ar': 'ara',
          'vi': 'vie',
        };
        final salt = DateTime.now().microsecondsSinceEpoch.toString();
        final appId = secret['appId']!;
        final signature = md5
            .convert(
              utf8.encode(
                '$appId${request.sourceText}$salt${secret['apiKey']}',
              ),
            )
            .toString();
        body = {
          'q': request.sourceText,
          'from':
              languageCodes[request.detectedLanguage] ??
              request.detectedLanguage ??
              'auto',
          'to': languageCodes[request.targetLanguage] ?? request.targetLanguage,
          'appid': appId,
          'salt': salt,
          'sign': signature,
        };
        http.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        );
        http.add(
          utf8.encode(Uri(queryParameters: body as Map<String, String>).query),
        );
      } else {
        if (config.kind == 'google') {
          http.headers.set('x-goog-api-key', secret['apiKey']!);
          body = {
            'q': request.sourceText,
            'target': request.targetLanguage,
            'format': 'text',
            if (request.detectedLanguage != null)
              'source': request.detectedLanguage,
          };
        } else {
          final system =
              config.prompt +
              (config.semanticPairs
                  ? '\n本次启用双语段落对照，以下格式要求优先于“只输出译文”：'
                        '输入 paragraphs 按原文段落编号，结合全文语义逐段完整翻译，不概括、不合并、不遗漏。'
                        '只输出一个合法 JSON 对象：{"segments":[{"id":0,"translation":"该段完整译文"}]}。'
                        '每个输入编号必须按原顺序出现且仅出现一次，译文不能为空；保留段内格式。'
                        '原文由应用按编号显示，不必重复输出原文或整篇译文。不要输出思考过程、Markdown 围栏或解释。'
                  : '\n只输出完整译文，不附加解释。');
          final input = jsonEncode({
            'source_language': request.detectedLanguage,
            'target_language': request.targetLanguage,
            if (config.semanticPairs)
              'paragraphs': [
                for (final (index, text) in modelSourceParagraphs(
                  request.sourceText,
                ).indexed)
                  {'id': index, 'text': text},
              ]
            else
              'text': request.sourceText,
          });
          if (config.kind != 'anthropic') {
            http.headers.set('Authorization', 'Bearer ${secret['apiKey']}');
            body = {
              'model': config.model,
              'stream': true,
              // DeepSeek 用协议参数关闭思考；提示词中的 no_think 不能替代接口约束。
              if (config.kind == 'deepseek' ||
                  Uri.parse(base).host == 'api.deepseek.com')
                'thinking': {'type': 'disabled'},
              if (config.semanticPairs &&
                  (config.kind == 'deepseek' ||
                      Uri.parse(base).host == 'api.deepseek.com'))
                'response_format': {'type': 'json_object'},
              'messages': [
                {'role': 'system', 'content': system},
                {'role': 'user', 'content': input},
              ],
            };
          } else {
            http.headers.set('x-api-key', secret['apiKey']!);
            http.headers.set('anthropic-version', '2023-06-01');
            body = {
              'model': config.model,
              'stream': true,
              'max_tokens': config.maxOutputTokens,
              'system': system,
              'messages': [
                {'role': 'user', 'content': input},
              ],
            };
          }
        }
        http.headers.contentType = ContentType.json;
        http.add(utf8.encode(jsonEncode(body)));
      }
      final response = await http.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _ApiFailure(switch (response.statusCode) {
          401 || 403 => '认证失败，请检查 API 凭据和服务权限。',
          429 => '请求过于频繁或额度不足，请稍后重试。',
          400 => '服务拒绝请求，请检查模型名称、语言与配置。',
          _ => '翻译服务请求失败（HTTP ${response.statusCode}）。',
        });
      }
      if (!config.isModel) {
        final data =
            jsonDecode(await utf8.decoder.bind(response).join()) as Map;
        late String text;
        if (config.kind == 'baidu') {
          if (data['error_code'] != null &&
              data['error_code'].toString() != '52000') {
            throw const _ApiFailure('百度翻译请求失败，请检查凭据、语种权限、额度和选区长度。');
          }
          text = (data['trans_result'] as List)
              .map((item) => item['dst'] as String)
              .join('\n');
        } else {
          text = (data['data']['translations'] as List)
              .map((item) => item['translatedText'] as String)
              .join('\n');
          // Google 的文本字段可能包含 HTML 实体；单次解码，保留原文本来含有的转义结构。
          text = text.replaceAllMapped(
            RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);'),
            (match) {
              const names = {
                'amp': '&',
                'lt': '<',
                'gt': '>',
                'quot': '"',
                'apos': "'",
              };
              final code = match[1]!;
              if (names.containsKey(code)) return names[code]!;
              final rune = int.parse(
                code.substring(code.startsWith('#x') ? 2 : 1),
                radix: code.startsWith('#x') ? 16 : 10,
              );
              return String.fromCharCode(rune);
            },
          );
        }
        if (text.trim().isEmpty) throw const _ApiFailure('服务未返回译文。');
        emit(TranslationUpdate(text));
        emit(const TranslationCompleted());
        return;
      }

      final buffer = StringBuffer();
      var finished = false;
      String? stopReason;
      var dataLines = <String>[];
      await for (final line
          in response.transform(utf8.decoder).transform(const LineSplitter())) {
        if (!active) return;
        // SSE 以空行结束事件；一个 JSON 事件可以跨多条 data 行。
        if (line.isNotEmpty) {
          if (line.startsWith('data:')) {
            dataLines.add(line.substring(5).replaceFirst(RegExp(r'^ '), ''));
          }
          continue;
        }
        if (dataLines.isEmpty) continue;
        final data = dataLines.join('\n');
        dataLines = [];
        if (data == '[DONE]') break;
        final chunk = jsonDecode(data) as Map;
        if (chunk['error'] != null || chunk['type'] == 'error') {
          throw const _ApiFailure('模型服务在生成过程中返回错误。');
        }
        var addition = '';
        if (config.kind != 'anthropic') {
          for (final choice in chunk['choices'] as List? ?? []) {
            if (choice['index'] != 0) continue;
            final delta = choice['delta'] as Map? ?? {};
            if (delta['refusal'] != null) throw const _ApiFailure('模型拒绝了本次翻译。');
            addition += delta['content'] as String? ?? '';
            stopReason = choice['finish_reason'] as String? ?? stopReason;
          }
          finished = stopReason != null;
        } else {
          switch (chunk['type']) {
            case 'content_block_start':
              if (chunk['content_block']['type'] == 'text') {
                addition = chunk['content_block']['text'] as String? ?? '';
              }
            case 'content_block_delta':
              if (chunk['delta']['type'] == 'text_delta') {
                addition = chunk['delta']['text'] as String;
              }
            case 'message_delta':
              stopReason =
                  chunk['delta']['stop_reason'] as String? ?? stopReason;
            case 'message_stop':
              finished = true;
          }
        }
        buffer.write(addition);
        if (!config.semanticPairs && addition.isNotEmpty) {
          emit(TranslationUpdate(addition));
        }
        if (finished) break;
      }
      if (stopReason == 'length' || stopReason == 'max_tokens') {
        throw const _ApiFailure('模型输出达到长度上限，译文不完整。请缩小选区或调整服务输出上限。');
      }
      if (!finished ||
          !['stop', 'end_turn'].contains(stopReason) ||
          buffer.toString().trim().isEmpty) {
        throw const _ApiFailure('模型未完整结束翻译，请重试。');
      }
      if (config.semanticPairs) {
        final parsed = parseModelResult(buffer.toString(), request.sourceText);
        emit(TranslationUpdate(parsed.translation));
        emit(TranslationCompleted(pairs: parsed.pairs));
      } else {
        emit(const TranslationCompleted());
      }
    }

    output.onListen = () async {
      try {
        await run().timeout(const Duration(seconds: 90));
      } on _ApiFailure catch (error) {
        emit(TranslationFailure(error.message));
      } on TimeoutException {
        emit(const TranslationFailure('翻译请求超时，请重试。'));
      } on SocketException {
        emit(const TranslationFailure('无法连接翻译服务，请检查网络与 API 地址。'));
      } catch (_) {
        // 不回显响应正文、请求 URL 或底层异常，避免将密钥和选区带入错误信息。
        emit(const TranslationFailure('翻译失败，请检查服务配置；返回内容可能不符合接口格式。'));
      } finally {
        active = false;
        client.close(force: true);
        await output.close();
      }
    };
    output.onCancel = () {
      active = false;
      client.close(force: true);
    };
    return output.stream;
  }
}

/// 仅承载由本应用定义的安全提示，区别于可能包含响应正文的解析异常。
class _ApiFailure implements Exception {
  const _ApiFailure(this.message);
  final String message;
}
