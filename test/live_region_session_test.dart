import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/settings/app_settings.dart';
import 'package:translate_app/src/settings/service_config.dart';
import 'package:translate_app/src/translation/live_region_session.dart';
import 'package:translate_app/src/translation/translation_types.dart';

/// 测试用单调时钟。elapse 只前进到目标时刻，并按截止点顺序触发回调。
final class ManualClock implements LiveRegionClock {
  DateTime current = DateTime.utc(2026);
  DateTime? deadline;
  void Function()? callback;

  /// 无参数；返回测试当前时刻。
  @override
  DateTime now() => current;

  /// delay 为等待，fire 为到点回调；只保留一个截止点。
  @override
  void schedule(Duration delay, void Function() fire) {
    deadline = current.add(delay);
    callback = fire;
  }

  /// 无参数；取消截止点，无返回值。
  @override
  void cancelSchedule() {
    deadline = null;
    callback = null;
  }

  /// step 为前进时长。先触发不晚于目标时刻的回调，再把时刻设到目标。
  void elapse(Duration step) {
    final target = current.add(step);
    while (deadline != null && !deadline!.isAfter(target)) {
      current = deadline!;
      final fire = callback;
      deadline = null;
      callback = null;
      fire?.call();
    }
    current = target;
  }
}

/// 可控的批量翻译服务。每次 translateBatch 记一条请求，事件由测试推送。
final class ScriptedProvider implements BatchTranslationProvider {
  /// parallel 为假时模拟同一时刻只允许一个批次的服务。
  ScriptedProvider({this.parallel = true});

  final bool parallel;
  final requests = <BatchTranslationRequest>[];
  final controllers = <StreamController<BatchTranslationEvent>>[];

  /// 每条请求发送时使用的模型名，由 providerFor 在构造服务时写入 model。
  final models = <String>[];
  String model = '';

  /// 到达终态之前被取消的请求下标。
  final cancelled = <int>[];
  final _settled = <int>{};

  /// 无参数；返回测试服务标识。
  @override
  String get id => 'svc';

  /// 无参数；测试不使用滑动上下文。
  @override
  bool get usesSlidingContext => false;

  /// 无参数；返回是否允许多个批次同时在途。
  @override
  bool get allowsParallelBatches => parallel;

  /// 实时翻译不调用单篇翻译。
  @override
  Stream<TranslationEvent> translate(TranslationRequest request) =>
      throw UnimplementedError();

  /// request 为本批次。返回由测试推送的事件流。
  @override
  Stream<BatchTranslationEvent> translateBatch(
    BatchTranslationRequest request, {
    required HttpClient client,
  }) {
    final index = requests.length;
    requests.add(request);
    models.add(model);
    final controller = StreamController<BatchTranslationEvent>(
      onCancel: () {
        if (!_settled.contains(index)) cancelled.add(index);
      },
    );
    controllers.add(controller);
    return controller.stream;
  }

  /// index 为请求下标，translations 为各段译文；null 表示该段没有译文。
  void complete(int index, List<String?> translations) {
    _settled.add(index);
    for (final (item, text) in translations.indexed) {
      if (text != null) controllers[index].add(BatchItemUpdate(item, text));
    }
    controllers[index].add(const BatchCompleted());
  }

  /// index 为请求下标，kind/message 为失败类别与原因。
  /// index 为请求序号，kind/message 为失败类别与原因，retryAfter 为服务要求的重试等待；让该请求失败。
  void fail(
    int index,
    TranslationFailureKind kind, [
    String message = '失败',
    Duration? retryAfter,
  ]) {
    _settled.add(index);
    controllers[index].add(BatchFailure(message, kind, retryAfter: retryAfter));
  }

  /// 无参数；返回每条请求携带的段落原文。
  List<List<String>> get sent => [for (final request in requests) request.texts];
}

/// 把已推送的翻译事件送到会话。流式回调晚于 settle 的同步返回。
Future<void> _delivered(LiveRegionSession session) async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
    await session.settle();
  }
}

/// session 为被测会话；返回当前盖层上按阅读顺序排列的译文，即原生盖层实际绘制的文字。
List<Object?> _overlayTexts(LiveRegionSession session) => [
  for (final overlay in session.view.overlays) overlay['text'],
];

/// generation 为代次，texts 为按阅读顺序排列的段落原文。返回每段各占一行矩形的 OCR 结果。
LiveOcrSample _frame(int generation, List<String> texts) => LiveOcrSample(
  generation: generation,
  blocks: [
    for (final (index, text) in texts.indexed)
      LiveTextBlock(text: text, x: 0, y: index * 20.0, width: 200, height: 20),
  ],
);

AppSettings _settings({
  String model = 'm1',
  String primary = 'zh-CN',
  String? secondary = 'en',
}) => AppSettings(
  primaryLanguage: primary,
  secondaryLanguage: secondary,
  defaultServiceId: 'svc',
  services: [
    ServiceConfig(
      id: 'svc',
      kind: 'openai',
      name: 'Model',
      baseUrl: 'https://example.com/v1',
      model: model,
    ),
  ],
);

/// provider 为被测会话使用的服务，clock 为测试时钟，detected 为语言识别结果。
/// 返回会话；providerFor 把当次设置的模型名写入 provider.model。
LiveRegionSession _session(
  ScriptedProvider provider,
  ManualClock clock, {
  String? detected = 'en',
}) => LiveRegionSession(
  providerFor: (settings) =>
      provider..model = settings.services.single.model,
  detectLanguage: (_) async => detected,
  clock: clock,
);

const _transient = TranslationFailureKind.transient;
const _halfSecond = Duration(milliseconds: 500);

void main() {
  test('首个非空画面的多个段落块合成一个批次，增量按下标盖到各自的矩形', () async {
    // 作用：一屏多段只发一次请求，译文按批次内下标归属。
    // 边界：首个非空画面不需要发送等待，时钟未前进即已发出。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['Hello', 'World']));
    expect(provider.sent, [
      ['Hello', 'World'],
    ]);
    expect(provider.requests.single.targetLanguage, 'zh-CN');
    expect(session.view.status, '正在翻译');
    provider.controllers.single.add(const BatchItemUpdate(1, '世'));
    await _delivered(session);
    // 只有下标 1 收到增量，盖层只出现在第二段的矩形上。
    expect(session.view.overlays, [
      {'text': '世', 'x': 0.0, 'y': 20.0, 'width': 200.0, 'height': 20.0},
    ]);
    provider.complete(0, ['你好', '界']);
    await _delivered(session);
    expect(_overlayTexts(session), ['你好', '世界']);
    expect(session.view.status, '已完成');
    expect(session.view.overlays, hasLength(2));
    await session.onOcr(_frame(1, ['Hello', 'World']));
    expect(provider.requests, hasLength(1));
  });

  test('画面只变化一个段落块时在途批次不取消，新段落块满足等待和间隔后才发送', () async {
    // 作用：局部变化不清空其余译文，也不打断在途请求。
    // 边界：C 在 100ms 出现，发送等待到 300ms，请求间隔到 500ms；499ms 不发，500ms 发。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A', 'B']));
    clock.elapse(const Duration(milliseconds: 100));
    await session.onOcr(_frame(1, ['A', 'C']));
    expect(provider.cancelled, isEmpty);
    provider.complete(0, ['甲', '乙']);
    await _delivered(session);
    expect(_overlayTexts(session), ['甲']);
    clock.elapse(const Duration(milliseconds: 399));
    await _delivered(session);
    expect(provider.requests, hasLength(1));
    clock.elapse(const Duration(milliseconds: 1));
    await _delivered(session);
    expect(provider.sent.last, ['C']);
  });

  test('段落块全部离开画面后取消批次，迟到事件不绘制', () async {
    // 作用：整页切换后旧批次不再占用在途名额，旧译文不落到新画面。
    // 边界：新画面与批次没有任何共同段落才取消。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    await session.onOcr(_frame(1, ['B']));
    expect(provider.cancelled, [0]);
    provider.controllers[0].add(const BatchItemUpdate(0, '甲'));
    provider.controllers[0].add(const BatchCompleted());
    await _delivered(session);
    expect(session.view.overlays, isEmpty);
  });

  test('回到已翻译的画面直接命中缓存，离开画面的在途结果也进入缓存', () async {
    // 作用：滚动后再次出现的段落不重复请求。
    // 边界：B 在批次完成前已离开画面，仍须写入缓存。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A', 'B']));
    await session.onOcr(_frame(1, ['A']));
    provider.complete(0, ['甲', '乙']);
    await _delivered(session);
    await session.onOcr(_frame(1, ['B']));
    expect(_overlayTexts(session), ['乙']);
    expect(session.view.status, '已完成');
    await session.onOcr(_frame(1, ['A', 'B']));
    expect(_overlayTexts(session), ['甲', '乙']);
    clock.elapse(const Duration(seconds: 5));
    await _delivered(session);
    expect(provider.requests, hasLength(1));
  });

  test('非首个画面的新段落块等满 200ms 才发送，原文不变不重置计时', () async {
    // 作用：过滤滚动与输入的中间态。
    // 边界：上一批次早已超过请求间隔，B 在 1000ms 出现，1199ms 不发，1200ms 发。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    provider.complete(0, ['甲']);
    await _delivered(session);
    clock.elapse(const Duration(seconds: 1));
    await session.onOcr(_frame(1, ['A', 'B']));
    clock.elapse(const Duration(milliseconds: 199));
    await session.onOcr(_frame(1, ['A', 'B']));
    expect(provider.requests, hasLength(1));
    clock.elapse(const Duration(milliseconds: 1));
    await _delivered(session);
    expect(provider.sent.last, ['B']);
  });

  test('单批最多 20 个段落块或 2000 字符，先到为准', () async {
    // 作用：超过单批上限时拆分，后一批受请求间隔约束。
    // 边界：21 段拆成 20＋1；两段各 1000 字符恰好 2000 可同批，再多 1 个字符就拆到下一批。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    final many = [for (var i = 0; i < 21; i++) 'p$i'];
    await session.onOcr(_frame(1, many));
    expect(provider.sent.single, many.sublist(0, 20));
    clock.elapse(_halfSecond);
    await _delivered(session);
    expect(provider.sent.last, ['p20']);

    final other = ScriptedProvider();
    final byChars = _session(other, ManualClock());
    byChars.start(_settings(), 1);
    await byChars.onOcr(_frame(1, ['a' * 1000, 'b' * 1000, 'c']));
    expect(other.sent.single, ['a' * 1000, 'b' * 1000]);
  });

  test('在途批次最多 3 个，不允许并行的服务只有 1 个', () async {
    // 作用：限制同时在途的请求数。
    // 边界：61 段需要 4 批；第 4 批在 1500ms 已满足间隔，但要等一个批次结束才发。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    final many = [for (var i = 0; i < 61; i++) 'p$i'];
    await session.onOcr(_frame(1, many));
    for (var i = 0; i < 3; i++) {
      clock.elapse(_halfSecond);
      await _delivered(session);
    }
    expect(provider.requests, hasLength(3));
    provider.complete(0, [for (var i = 0; i < 20; i++) '译$i']);
    await _delivered(session);
    expect(provider.sent.last, ['p60']);

    final serialClock = ManualClock();
    final serial = ScriptedProvider(parallel: false);
    final single = _session(serial, serialClock);
    single.start(_settings(), 1);
    await single.onOcr(_frame(1, many.sublist(0, 21)));
    serialClock.elapse(const Duration(seconds: 5));
    await _delivered(single);
    expect(serial.requests, hasLength(1));
    serial.complete(0, [for (var i = 0; i < 20; i++) '译$i']);
    await _delivered(single);
    expect(serial.sent.last, ['p20']);
  });

  test('临时错误按请求间隔重试，同一段落原文最多重试 3 次', () async {
    // 作用：网络波动可恢复，持续失败不无限发送。
    // 边界：首次请求加 3 次重试共 4 次；第 4 次失败后不再发送，离开画面再出现也不发送。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    for (var attempt = 0; attempt < 4; attempt++) {
      expect(provider.requests, hasLength(attempt + 1));
      provider.fail(attempt, _transient, '网络异常');
      await _delivered(session);
      clock.elapse(const Duration(milliseconds: 499));
      await _delivered(session);
      expect(provider.requests, hasLength(attempt + 1));
      clock.elapse(const Duration(milliseconds: 1));
      await _delivered(session);
    }
    expect(provider.requests, hasLength(4));
    expect(session.view.status, '网络异常');
    await session.onOcr(_frame(1, ['B']));
    clock.elapse(const Duration(seconds: 1));
    await _delivered(session);
    await session.onOcr(_frame(1, ['A', 'B']));
    clock.elapse(const Duration(seconds: 5));
    await _delivered(session);
    expect(provider.sent.last, ['B']);
    expect(provider.requests, hasLength(5));
  });

  test('语言识别抛错时批次按临时失败结束，按请求间隔重试并继续调度（#116）', () async {
    // 作用：识别异常不再让批次一直占用在途名额、界面停在「正在翻译」。
    // 边界：第 1 次识别抛错后没有发出请求、状态为「等待翻译」；499ms 不重试，500ms 重试并发出请求。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    var calls = 0;
    final session = LiveRegionSession(
      providerFor: (settings) =>
          provider..model = settings.services.single.model,
      detectLanguage: (_) async {
        calls++;
        if (calls == 1) throw StateError('识别失败');
        return 'en';
      },
      clock: clock,
    );
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    await _delivered(session);
    expect(provider.requests, isEmpty);
    expect(session.view.status, '等待翻译');
    clock.elapse(const Duration(milliseconds: 499));
    await _delivered(session);
    expect(provider.requests, isEmpty);
    clock.elapse(const Duration(milliseconds: 1));
    await _delivered(session);
    expect(provider.sent, [
      ['A'],
    ]);
    expect(session.view.status, '正在翻译');
  });

  test('频率受限按 2/4 秒或 Retry-After 退避后重试，成功一批后退避从 2 秒重新计（#118）', () async {
    // 作用：限流不再停止会话，而是等待后再发送。
    // 边界：连续两次无 Retry-After 依次等 2 秒、4 秒，第三次带 Retry-After 3 秒时等 3 秒（各差 1ms 不发）；
    // 成功完成一批后新段落再受限时重新等 2 秒。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    const limited = TranslationFailureKind.rateLimited;
    const millisecond = Duration(milliseconds: 1);

    /// index 为受限的请求序号，retryAfter 为服务给出的等待，wait 为预期退避；断言到期前不发、到期即发。
    Future<void> limitAndWait(
      int index,
      Duration wait, [
      Duration? retryAfter,
    ]) async {
      provider.fail(index, limited, '请求过于频繁', retryAfter);
      await _delivered(session);
      clock.elapse(wait - millisecond);
      await _delivered(session);
      expect(provider.requests, hasLength(index + 1));
      clock.elapse(millisecond);
      await _delivered(session);
      expect(provider.requests, hasLength(index + 2));
    }

    await limitAndWait(0, const Duration(seconds: 2));
    await limitAndWait(1, const Duration(seconds: 4));
    await limitAndWait(
      2,
      const Duration(seconds: 3),
      const Duration(seconds: 3),
    );
    provider.complete(3, ['甲']);
    await _delivered(session);
    await session.onOcr(_frame(1, ['A', 'B']));
    clock.elapse(const Duration(seconds: 1));
    await _delivered(session);
    expect(provider.sent.last, ['B']);
    await limitAndWait(4, const Duration(seconds: 2));
  });

  test('服务级明确错误后本次会话不再发送，新会话恢复发送', () async {
    // 作用：密钥或额度错误不重试，也不为新段落继续发请求。
    // 边界：错误之后出现的新段落块同样不发送；重新开始会话后才恢复。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    provider.fail(0, TranslationFailureKind.service, '认证失败');
    await _delivered(session);
    await session.onOcr(_frame(1, ['A', 'B']));
    clock.elapse(const Duration(seconds: 5));
    await _delivered(session);
    expect(provider.requests, hasLength(1));
    expect(session.view.status, '认证失败');
    session.start(_settings(), 2);
    await session.onOcr(_frame(2, ['A']));
    expect(provider.requests, hasLength(2));
  });

  test('段落级明确错误：多段批次各自单独补发，单段不再发送', () async {
    // 作用：一个段落被拒绝不拖累同批的其他段落。
    // 边界：两段批次失败后拆成两个单段批次；A 再次被拒后不再发送，B 正常完成。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A', 'B']));
    provider.fail(0, TranslationFailureKind.paragraph, '模型拒绝');
    await _delivered(session);
    clock.elapse(_halfSecond);
    await _delivered(session);
    clock.elapse(_halfSecond);
    await _delivered(session);
    expect(provider.sent.sublist(1), [
      ['A'],
      ['B'],
    ]);
    provider.fail(1, TranslationFailureKind.paragraph, '模型拒绝');
    provider.complete(2, ['乙']);
    await _delivered(session);
    clock.elapse(const Duration(seconds: 5));
    await _delivered(session);
    expect(provider.requests, hasLength(3));
    expect(_overlayTexts(session), ['乙']);
    expect(session.view.status, '模型拒绝');
  });

  test('批次内没有译文的段落块单独补发一次，仍没有译文则不再发送', () async {
    // 作用：编号缺失时不把别的译文错盖到该段。
    // 边界：补发只有一次，第二次仍为空后请求数不再增加。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A', 'B']));
    provider.complete(0, ['甲', null]);
    await _delivered(session);
    expect(_overlayTexts(session), ['甲']);
    clock.elapse(_halfSecond);
    await _delivered(session);
    expect(provider.sent.last, ['B']);
    provider.complete(1, [null]);
    await _delivered(session);
    clock.elapse(const Duration(seconds: 5));
    await _delivered(session);
    expect(provider.requests, hasLength(2));
    expect(session.view.status, '服务未返回该段译文。');
  });

  test('暂停取消在途批次并撤掉盖层，恢复后命中缓存的段落块不重复发送', () async {
    // 作用：暂停停止网络工作，缓存跨暂停保留。
    // 边界：A 已完成、C 在途时暂停；恢复后只重新发送 C。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    provider.complete(0, ['甲']);
    await _delivered(session);
    await session.onOcr(_frame(1, ['A', 'C']));
    clock.elapse(_halfSecond);
    await _delivered(session);
    expect(provider.sent.last, ['C']);
    session.pause(2);
    await _delivered(session);
    expect(provider.cancelled, [1]);
    expect(session.view.phase, 'paused');
    expect(session.view.overlays, isEmpty);
    await session.onOcr(_frame(2, ['D']));
    expect(provider.requests, hasLength(2));
    session.resume(3);
    await session.onOcr(_frame(3, ['A', 'C']));
    expect(_overlayTexts(session), ['甲']);
    clock.elapse(_halfSecond);
    await _delivered(session);
    expect(provider.sent.sublist(2), [
      ['C'],
    ]);
  });

  test('结束、放弃与采集失效都撤下盖层并清空缓存，采集失效显示原因', () async {
    // 作用：三种终止方式的阶段、盖层与缓存边界。
    // 边界：每次终止后的新会话对同一段落重新请求，说明缓存不跨会话；采集失效的原因写入状态。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    provider.complete(0, ['甲']);
    await _delivered(session);
    session.end(2);
    expect(session.view.phase, 'ended');
    expect(session.view.overlays, isEmpty);
    session.start(_settings(), 3);
    await session.onOcr(_frame(3, ['A']));
    expect(provider.requests, hasLength(2));
    provider.complete(1, ['甲']);
    await _delivered(session);
    session.discard(4);
    expect(session.view.phase, 'discarded');
    expect(session.view.overlays, isEmpty);
    session.start(_settings(), 5);
    await session.onOcr(_frame(5, ['A']));
    provider.complete(2, ['甲']);
    await _delivered(session);
    session.captureUnavailable(6, '目标显示器已移除。');
    expect(session.view.phase, 'ended');
    expect(session.view.overlays, isEmpty);
    expect(session.view.status, '目标显示器已移除。');
  });

  test('修改设置不重译未变化的段落块，新出现的段落块使用新设置', () async {
    // 作用：设置变更不打断当前画面。
    // 边界：A 保持旧译文且不再请求；B 的请求使用新模型。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    provider.complete(0, ['甲']);
    await _delivered(session);
    session.noteSettings(_settings(model: 'm2'));
    await session.onOcr(_frame(1, ['A']));
    clock.elapse(const Duration(seconds: 1));
    await _delivered(session);
    expect(provider.requests, hasLength(1));
    await session.onOcr(_frame(1, ['A', 'B']));
    clock.elapse(_halfSecond);
    await _delivered(session);
    expect(provider.sent.last, ['B']);
    expect(provider.models, ['m1', 'm2']);
    expect(_overlayTexts(session), ['甲']);
  });

  test('超过 50000 个字符的段落块只在本地提示，刚好 50000 仍发送', () async {
    // 作用：本地长度校验不通过时不发网络请求。
    // 边界：50001 拒发，50000 发送。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['x' * 50001]));
    expect(provider.requests, isEmpty);
    expect(session.view.status, '文字超过 50,000 个字符，未发送翻译请求。');
    await session.onOcr(_frame(1, ['y' * 50000]));
    clock.elapse(const Duration(milliseconds: 200));
    await _delivered(session);
    expect(provider.requests, hasLength(1));
  });

  test('中文识别失败时按中文处理；已是目标语言不请求；译文与原文相同不盖层', () async {
    // 作用：语言方向的三个边界。
    // 边界：识别为空且含汉字时按中文译成次要语言；没有次要语言且已是主要语言时不发请求。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock, detected: null);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['你好']));
    expect(provider.requests.single.detectedLanguage, 'zh-CN');
    expect(provider.requests.single.targetLanguage, 'en');
    provider.complete(0, ['你好']);
    await _delivered(session);
    expect(session.view.status, '已完成');
    expect(session.view.overlays, isEmpty);

    final other = ScriptedProvider();
    final same = _session(other, ManualClock());
    same.start(_settings(primary: 'en', secondary: null), 1);
    await same.onOcr(_frame(1, ['Hello']));
    expect(other.requests, isEmpty);
    expect(same.view.status, '已完成');
    expect(same.view.overlays, isEmpty);
  });

  test('同一段落原文出现在两处时只翻译一次，两处都盖上译文', () async {
    // 作用：重复文字共用一份译文。
    // 边界：请求里该原文只出现一次，盖层数量等于出现次数 2。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['OK', 'OK']));
    expect(provider.sent.single, ['OK']);
    provider.complete(0, ['确定']);
    await _delivered(session);
    expect(session.view.overlays.map((item) => item['y']), [0.0, 20.0]);
  });

  test('空白与识别失败分开显示，都撤去译文并取消在途批次', () async {
    // 作用：无文字和识别错误不发请求，旧译文不留在画面上。
    // 边界：非空之后变为空白时取消在途批次；识别失败显示错误原文。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(const LiveOcrSample(generation: 1));
    expect(session.view.status, '未识别到文字');
    expect(provider.requests, isEmpty);
    await session.onOcr(_frame(1, ['A']));
    await session.onOcr(_frame(1, ['   ']));
    await _delivered(session);
    expect(provider.cancelled, [0]);
    expect(session.view.status, '未识别到文字');
    expect(session.view.overlays, isEmpty);
    await session.onOcr(const LiveOcrSample(generation: 1, failure: '识别失败'));
    expect(session.view.status, '识别失败');
  });

  test('批次结束时随快照给出一条计时，之后的快照不再重复', () async {
    // 作用：排查日志依据的批次计时来自会话的真实时刻。
    // 边界：B 在 1000ms 出现、1200ms 发出，等待 200ms；首段译文在 +120ms，完成在 +300ms，两者不同。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final views = <LiveRegionView>[];
    final session = LiveRegionSession(
      providerFor: (_) => provider,
      detectLanguage: (_) async => 'en',
      clock: clock,
      onView: views.add,
    );
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    provider.complete(0, ['甲']);
    await _delivered(session);
    clock.elapse(const Duration(seconds: 1));
    await session.onOcr(_frame(1, ['A', 'Bcd']));
    clock.elapse(const Duration(milliseconds: 200));
    await _delivered(session);
    views.clear();
    clock.elapse(const Duration(milliseconds: 120));
    provider.controllers[1].add(const BatchItemUpdate(0, '乙'));
    await _delivered(session);
    clock.elapse(const Duration(milliseconds: 180));
    provider.complete(1, []);
    await _delivered(session);
    expect([for (final view in views) ...view.metrics], [
      {
        'blocks': 1,
        'chars': 3,
        'waitMs': 200,
        'firstMs': 120,
        'totalMs': 300,
        'inflight': 1,
        'outcome': 'completed',
      },
    ]);
    await session.onOcr(_frame(1, ['A', 'Bcd']));
    expect(session.view.metrics, isEmpty);
  });

  test('新会话不接收上一次代次的 OCR', () async {
    // 作用：迟到的识别结果不能进入新会话。
    // 边界：代次 1 的结果在代次 2 的会话中被忽略。
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    session.start(_settings(), 2);
    await session.onOcr(_frame(1, ['A']));
    expect(provider.requests, isEmpty);
    // 被接收的画面会把状态改为「正在翻译」；仍为「正在识别」说明旧代次结果未进入会话。
    expect(session.view.status, '正在识别');
  });
}
