import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/selection/selection_session.dart';
import 'package:translate_app/src/translation/language_direction.dart';
import 'package:translate_app/src/translation/translation_types.dart';

class RecordingProvider implements TranslationProvider {
  RecordingProvider({
    this.events = const [TranslationUpdate('你好'), TranslationCompleted()],
  });

  @override
  final id = 'recording';
  final List<TranslationEvent> events;
  final requests = <TranslationRequest>[];

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {
    requests.add(request);
    for (final event in events) {
      yield event;
    }
  }
}

void main() {
  final language = LanguageDirection(primaryCode: 'zh-CN', secondaryCode: 'en');

  test(
    'explicit activation preserves prepared paragraphs in request and card',
    () async {
      // 捕获只显示按钮；明确激活后的格式补读结果才进入翻译请求和双语原文。
      final provider = RecordingProvider();
      final session = SelectionSession(
        provider: provider,
        detectLanguage: (_) async => 'en',
      );
      final read = Completer<String?>();
      session.begin(sessionId: 'formatted', text: 'First.Second.');
      final pending = session.activate(readSelection: () => read.future);
      expect(session.snapshot.phase, TranslationPhase.translating);
      expect(provider.requests, isEmpty);
      read.complete('First.\n\nSecond.');
      await pending;
      expect(provider.requests.single.sourceText, 'First.\n\nSecond.');
      expect(session.snapshot.sourceText, 'First.\n\nSecond.');
      expect(session.snapshot.phase, TranslationPhase.completed);
    },
  );

  test(
    'late source read cannot translate or replace a newer selection',
    () async {
      // 原文读取也是异步边界；新选区到达后，旧读取结果不能发请求或覆盖新卡片。
      final provider = RecordingProvider();
      final session = SelectionSession(
        provider: provider,
        detectLanguage: (_) async => 'en',
      );
      final read = Completer<String?>();
      session.begin(sessionId: 'old', text: 'Old');
      final pending = session.activate(readSelection: () => read.future);
      session.begin(sessionId: 'new', text: 'New');
      read.complete('Old formatted');
      await pending;
      expect(session.sessionId, 'new');
      expect(session.snapshot.sourceText, 'New');
      expect(session.snapshot.phase, TranslationPhase.trigger);
      expect(provider.requests, isEmpty);
    },
  );

  test(
    'missing or oversized prepared text never reaches the provider',
    () async {
      // null 是原生会话失效边界；补读后超过 50,000 字符也必须在请求前拦截。
      for (final text in [null, 'x' * (SelectionSession.selectionLimit + 1)]) {
        final provider = RecordingProvider();
        final session = SelectionSession(
          provider: provider,
          detectLanguage: (_) async => 'en',
        );
        session.begin(sessionId: 'source', text: 'Captured');
        await session.activate(readSelection: () async => text);
        expect(
          session.snapshot.phase,
          text == null ? TranslationPhase.idle : TranslationPhase.sizeLimited,
        );
        expect(provider.requests, isEmpty);
      }
    },
  );

  test('gesture with text shows trigger without calling provider', () {
    final provider = RecordingProvider();
    final session = SelectionSession(
      detectLanguage: (_) async => 'en',
      provider: provider,
      language: language,
    );
    session.begin(sessionId: 's1', text: 'Hello');
    expect(session.snapshot.phase, TranslationPhase.trigger);
    expect(session.snapshot.sourceText, 'Hello');
    expect(provider.requests, isEmpty);
  });

  test('blank text stays idle', () {
    final session = SelectionSession(
      detectLanguage: (_) async => 'en',
      provider: RecordingProvider(),
      language: language,
    );
    session.begin(sessionId: 's1', text: '  \n');
    expect(session.snapshot.phase, TranslationPhase.idle);
  });

  test(
    'late translation cannot reopen a dismissed or replaced selection',
    () async {
      // 在首个异步结果到达前结束 s1 并创建 s2；旧更新和完成事件都不能污染新选区。
      final session = SelectionSession(
        detectLanguage: (_) async => 'en',
        provider: RecordingProvider(),
        language: language,
      );
      session.begin(sessionId: 's1', text: 'Hello');
      final pending = session.activate();
      session.dismiss();
      session.begin(sessionId: 's2', text: 'New selection');
      await pending;
      expect(session.sessionId, 's2');
      expect(session.snapshot.phase, TranslationPhase.trigger);
      expect(session.snapshot.sourceText, 'New selection');
      expect(session.snapshot.translatedText, isEmpty);
    },
  );

  test('activate translates and assembles updates', () async {
    final provider = RecordingProvider(
      events: const [
        TranslationUpdate('你'),
        TranslationUpdate('好'),
        TranslationCompleted(),
      ],
    );
    final session = SelectionSession(
      detectLanguage: (_) async => 'en',
      provider: provider,
      language: language,
    );
    session.begin(sessionId: 's1', text: 'Hello');
    await session.activate();
    expect(session.snapshot.phase, TranslationPhase.completed);
    expect(session.snapshot.translatedText, '你好');
    expect(provider.requests.single.sourceText, 'Hello');
  });

  test('oversize selection stays local', () async {
    final provider = RecordingProvider();
    final session = SelectionSession(
      detectLanguage: (_) async => 'en',
      provider: provider,
      language: language,
    );
    session.begin(
      sessionId: 's1',
      text: 'a' * (SelectionSession.selectionLimit + 1),
    );
    await session.activate();
    expect(session.snapshot.phase, TranslationPhase.sizeLimited);
    expect(provider.requests, isEmpty);
  });

  test('limit inclusive still translates', () async {
    final provider = RecordingProvider();
    final session = SelectionSession(
      detectLanguage: (_) async => 'en',
      provider: provider,
      language: language,
    );
    session.begin(sessionId: 's1', text: 'a' * SelectionSession.selectionLimit);
    await session.activate();
    expect(session.snapshot.phase, TranslationPhase.completed);
    expect(provider.requests, hasLength(1));
  });
}
