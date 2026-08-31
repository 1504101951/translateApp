import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/selection/selection_session.dart';
import 'package:translate_app/src/translation/language_direction.dart';
import 'package:translate_app/src/translation/translation_types.dart';

class RecordingProvider implements TranslationProvider {
  RecordingProvider({this.events = const [TranslationUpdate('你好'), TranslationCompleted()]});

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

  test('gesture with text shows trigger without calling provider', () {
    final provider = RecordingProvider();
    final session = SelectionSession(provider: provider, language: language);
    session.begin(sessionId: 's1', text: 'Hello');
    expect(session.snapshot.phase, TranslationPhase.trigger);
    expect(session.snapshot.sourceText, 'Hello');
    expect(provider.requests, isEmpty);
  });

  test('blank text stays idle', () {
    final session = SelectionSession(provider: RecordingProvider(), language: language);
    session.begin(sessionId: 's1', text: '  \n');
    expect(session.snapshot.phase, TranslationPhase.idle);
  });

  test('activate translates and assembles updates', () async {
    final provider = RecordingProvider(
      events: const [TranslationUpdate('你'), TranslationUpdate('好'), TranslationCompleted()],
    );
    final session = SelectionSession(provider: provider, language: language);
    session.begin(sessionId: 's1', text: 'Hello');
    await session.activate();
    expect(session.snapshot.phase, TranslationPhase.completed);
    expect(session.snapshot.translatedText, '你好');
    expect(provider.requests.single.sourceText, 'Hello');
  });

  test('oversize selection stays local', () async {
    final provider = RecordingProvider();
    final session = SelectionSession(provider: provider, language: language);
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
    final session = SelectionSession(provider: provider, language: language);
    session.begin(
      sessionId: 's1',
      text: 'a' * SelectionSession.selectionLimit,
    );
    await session.activate();
    expect(session.snapshot.phase, TranslationPhase.completed);
    expect(provider.requests, hasLength(1));
  });
}
