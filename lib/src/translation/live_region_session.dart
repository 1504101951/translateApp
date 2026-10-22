import 'dart:async';
import 'dart:io';

import 'package:characters/characters.dart';

import '../common/constants/text_limits.dart';
import '../settings/app_settings.dart';
import 'language_direction.dart';
import 'live_block_cache.dart';
import 'translation_types.dart';

/// 已批准的实时翻译调度值。
///
/// captureMinInterval 是 SCStream 供帧间隔，只节流系统输出，不保证固定帧率。
/// candidateCoalescingDelay 按单个段落块计时：段落原文保持不变达到该时长后才可发送。
/// requestStartInterval 是两个批次开始的最小间隔，不是完成后再等待。
/// maxInflightBatches 是同时在途的批次上限；不允许并行的服务固定为 1。
/// maxBatchBlocks 与 maxBatchChars 是单个批次的段落块数与字符数上限，先到为准。
/// cacheBudgetBytes 是段落块缓存的内存预算，单位字节。
/// transientRetryLimit 是同一段落原文在一次会话内临时错误后的重试上限。
abstract final class LiveRegionSchedule {
  static const captureMinInterval = Duration(milliseconds: 200);
  static const candidateCoalescingDelay = Duration(milliseconds: 200);
  static const requestStartInterval = Duration(milliseconds: 500);
  static const maxInflightBatches = 3;
  static const maxBatchBlocks = 20;
  static const maxBatchChars = 2000;
  static const cacheBudgetBytes = 100 * 1024 * 1024;
  static const transientRetryLimit = 3;
}

/// 调度使用的时钟。now 在同一次会话内单调；schedule 只保留一个截止点。
abstract class LiveRegionClock {
  /// 无参数；返回本次调度使用的当前时刻。
  DateTime now();

  /// delay 为距 now 的正间隔，fire 到点后执行；替换上一个尚未触发的截止点。
  void schedule(Duration delay, void Function() fire);

  /// 无参数；取消尚未触发的截止点，无返回值。
  void cancelSchedule();
}

/// 系统单调时钟。用启动后的停表，避免壁钟回拨缩短请求间隔。
final class SystemLiveRegionClock implements LiveRegionClock {
  final Stopwatch _watch = Stopwatch()..start();
  Timer? _timer;

  /// 无参数；返回停表经过的毫秒，不读取壁钟。
  @override
  DateTime now() =>
      DateTime.fromMillisecondsSinceEpoch(_watch.elapsedMilliseconds);

  /// delay 为等待时长，fire 为到点回调；取消旧计时后再登记，避免重复发送。
  @override
  void schedule(Duration delay, void Function() fire) {
    _timer?.cancel();
    _timer = Timer(delay, fire);
  }

  /// 无参数；停止尚未触发的计时，无返回值。
  @override
  void cancelSchedule() {
    _timer?.cancel();
    _timer = null;
  }
}

/// 一个段落块。坐标是屏幕点、左下原点；没有坐标时只参与翻译，不画盖层。
class LiveTextBlock {
  /// text 为该段原文。x/y/width/height 为段落外接矩形，缺任一坐标则不覆盖。
  const LiveTextBlock({
    required this.text,
    this.x,
    this.y,
    this.width,
    this.height,
  });

  final String text;
  final double? x;
  final double? y;
  final double? width;
  final double? height;

  /// 无参数。宽高为正且坐标完整时才能盖住这一段。
  bool get placeable =>
      x != null &&
      y != null &&
      width != null &&
      height != null &&
      width! > 0 &&
      height! > 0;
}

/// 一次设备 OCR 结果。failure 非空表示识别失败；blocks 为按阅读顺序排列的段落块。
class LiveOcrSample {
  /// generation 为捕获代次。text 为整段原文；blocks 非空时以块文本拼接为准。
  const LiveOcrSample({
    required this.generation,
    this.text,
    this.failure,
    this.blocks = const [],
  });

  final int generation;
  final String? text;
  final String? failure;
  final List<LiveTextBlock> blocks;
}

/// 结果窗口渲染的业务快照。不含密钥、凭据或调度中间态。
class LiveRegionView {
  /// phase 为 idle/running/paused/ended/discarded；banner 为暂停或结束标注。
  const LiveRegionView({
    required this.generation,
    required this.phase,
    required this.source,
    required this.translation,
    required this.status,
    this.banner,
    this.overlays = const [],
    this.metrics = const [],
  });

  static const idle = LiveRegionView(
    generation: 0,
    phase: 'idle',
    source: '',
    translation: '',
    status: '',
  );

  final int generation;
  final String phase;
  final String source;
  final String translation;
  final String status;
  final String? banner;

  /// 只包含已经能归属到段落块的译文。坐标为屏幕点。
  final List<Map<String, Object>> overlays;

  /// 自上一次快照以来结束的批次计时，每个批次只出现一次；只含数量、毫秒数与结果，不含文字。
  /// 字段：blocks 段落块数，chars 字符数，waitMs 段落块出现到批次开始的最长等待，
  /// firstMs 批次开始到首段译文（没有译文为 -1），totalMs 批次开始到结束，
  /// inflight 结束时的在途批次数，outcome 为 completed、cancelled 或失败类别名。
  final List<Map<String, Object>> metrics;

  /// 无参数；返回可跨引擎传递的快照，不包含服务密钥。
  Map<String, Object?> toMap() => {
    'generation': generation,
    'phase': phase,
    'source': source,
    'translation': translation,
    'status': status,
    'banner': banner,
    'overlays': overlays,
    'metrics': metrics,
  };
}

/// 当前画面中的一个段落原文。同文出现在多处时共用一份译文，各处保留自己的矩形。
class _Paragraph {
  /// text 为段落原文，observedAt 为该原文本次出现在画面上的时刻；
  /// immediate 为真表示属于会话首个非空画面，不需要发送等待。
  _Paragraph(this.text, this.observedAt, {required this.immediate});

  final String text;
  final DateTime observedAt;
  final bool immediate;
  var places = <LiveTextBlock>[];

  /// 画面上显示的译文；在途批次的增量也写在这里。
  var shown = '';

  /// 译文是否已完整。
  var done = false;

  /// 为真时该段落单独成批：编号对不上，或所在的多段批次遇到段落级错误。
  var alone = false;
}

/// 一个在途批次。keys 为各段落在缓存中的键，partial 为各段落已收到的译文。
class _Batch {
  /// texts 为批次内的段落原文，keys 为按本批次设置计算的缓存键；
  /// startedAt 为批次开始时刻，wait 为其中段落块从出现到开始的最长等待。
  _Batch(this.texts, this.keys, this.startedAt, this.wait)
    : partial = [for (final _ in texts) StringBuffer()];

  final List<String> texts;
  final List<String> keys;
  final List<StringBuffer> partial;
  final DateTime startedAt;
  final Duration wait;

  /// 首段译文到达的时刻。
  DateTime? firstAt;
  StreamSubscription<BatchTranslationEvent>? subscription;
  var cancelled = false;
}

/// 主引擎的实时区域翻译会话。
///
/// 翻译单元是段落块。每帧识别结果逐块查段落块缓存，未命中的段落块合并为批次发送。
/// 只保存本次会话的缓存、调度和拒绝迟到事件所需的内存状态，不写历史。
class LiveRegionSession {
  /// providerFor 按设置构造服务；detectLanguage 为本地语言识别；clock 为单调时钟。
  /// onView 在快照变化时通知原生盖层。inputLimit 为单个段落块拒发网络请求的字符上限。
  LiveRegionSession({
    required this.providerFor,
    required this.detectLanguage,
    required this.clock,
    this.onView,
    this.inputLimit = TextLimits.translationInput,
  });

  final BatchTranslationProvider Function(AppSettings settings) providerFor;
  final Future<String?> Function(String text) detectLanguage;
  final LiveRegionClock clock;
  final void Function(LiveRegionView view)? onView;
  final int inputLimit;

  LiveRegionView view = LiveRegionView.idle;

  final _cache = LiveBlockCache(
    budgetBytes: LiveRegionSchedule.cacheBudgetBytes,
  );
  final _inflight = <_Batch>[];
  // 尚未随快照发布的批次计时。
  var _metrics = <Map<String, Object>>[];
  // 键为段落原文，顺序即当前画面的阅读顺序。
  var _paragraphs = <String, _Paragraph>{};
  var _generation = 0;
  var _phase = 'idle';
  // 画面没有段落块时显示的状态：正在识别、未识别到文字或识别错误。
  var _notice = '';
  String? _banner;
  // 服务级明确错误的提示；非空时本次会话不再发送批次。
  String? _halt;
  // 最近一次段落级或临时错误的提示。
  String? _lastError;
  AppSettings? _latestSettings;
  HttpClient? _client;
  var _firstNonEmpty = true;
  DateTime? _lastBatchStart;
  var _epoch = 0;
  var _pending = 0;
  final List<Completer<void>> _waiters = [];

  /// settings 为开始时的当前偏好，generation 为捕获代次。
  /// 建立空的运行快照并返回。不继承上一次的文字、译文、缓存或计时。
  LiveRegionView start(AppSettings settings, int generation) {
    if (generation <= _generation && _phase != 'idle') return view;
    // 新会话不再等待上一次取消；旧完成回调不能减少这次的进行计数。
    _epoch += 1;
    _pending = 0;
    for (final waiter in List<Completer<void>>.of(_waiters)) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
    // 旧批次、连接和缓存全部作废，迟到增量不能写入新代次。
    _release();
    _client = HttpClient();
    _generation = generation;
    _phase = 'running';
    _latestSettings = settings;
    _paragraphs = {};
    _firstNonEmpty = true;
    _lastBatchStart = null;
    _halt = null;
    _lastError = null;
    _notice = '正在识别';
    _banner = null;
    return _publish();
  }

  /// generation 为暂停后的新代次。停止发送并保留当前内容与缓存；返回暂停快照。
  LiveRegionView pause(int generation) {
    if (_phase != 'running' || generation <= _generation) return view;
    _generation = generation;
    clock.cancelSchedule();
    _phase = 'paused';
    // 尚未取得文字时只显示暂停。
    _banner = _paragraphs.isEmpty ? '已暂停' : '暂停快照';
    _cancelAll();
    return _publish();
  }

  /// generation 为恢复后的新代次。沿用同一会话的缓存和请求间隔；返回运行快照。
  LiveRegionView resume(int generation) {
    if (_phase != 'paused' || generation <= _generation) return view;
    _generation = generation;
    _phase = 'running';
    _banner = null;
    return _publish();
  }

  /// generation 为结束后的新代次。停止工作、清空缓存并保留最后结果；返回带“已结束”的快照。
  LiveRegionView end(int generation) {
    if (_phase == 'idle' ||
        _phase == 'discarded' ||
        generation <= _generation) {
      return view;
    }
    _generation = generation;
    _phase = 'ended';
    _banner = '已结束';
    _release();
    return _publish();
  }

  /// generation 为放弃后的新代次。清空本次内容与缓存；返回 discarded 快照。
  LiveRegionView discard(int generation) {
    if (generation <= _generation && _phase != 'idle') return view;
    _generation = generation;
    _phase = 'discarded';
    _paragraphs = {};
    _notice = '';
    _halt = null;
    _lastError = null;
    _banner = null;
    _release();
    return _publish();
  }

  /// generation 为失效后的新代次，message 为用户可读原因。
  /// 清空原文和译文，避免旧结果继续显示为当前译文；返回结束快照。
  LiveRegionView captureUnavailable(int generation, String message) {
    if (_phase != 'running' && _phase != 'paused') return view;
    if (generation <= _generation) return view;
    _generation = generation;
    _phase = 'ended';
    _paragraphs = {};
    _notice = message;
    _halt = null;
    _lastError = null;
    _banner = null;
    _release();
    return _publish();
  }

  /// settings 为已提交的新偏好。不打断在途批次，也不重译画面上未变化的段落块；
  /// 之后发送的批次和新出现的段落块使用新偏好。无返回值。
  void noteSettings(AppSettings settings) {
    _latestSettings = settings;
  }

  /// sample 为当前代次的 OCR 结果。逐块查缓存并调度；返回处理完本地决策后的快照。
  Future<LiveRegionView> onOcr(LiveOcrSample sample) async {
    _applyOcr(sample);
    await settle();
    return view;
  }

  /// 无参数；等待检测语言、取消订阅等本地异步步骤结束，返回完成的 Future。
  Future<void> settle() {
    if (_pending == 0) return Future<void>.value();
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _applyOcr(LiveOcrSample sample) {
    if (sample.generation != _generation || _phase != 'running') return;
    if (sample.failure != null) {
      _clearScreen(sample.failure!);
      return;
    }
    // 没有块列表时，把整段原文当作一个无坐标的段落块。
    final blocks = [
      for (final block
          in sample.blocks.isEmpty
              ? [LiveTextBlock(text: sample.text ?? '')]
              : sample.blocks)
        if (block.text.trim().isNotEmpty) block,
    ];
    if (blocks.isEmpty) {
      _clearScreen('未识别到文字');
      return;
    }
    final now = clock.now();
    final immediate = _firstNonEmpty;
    _firstNonEmpty = false;
    final settings = _latestSettings!;
    final next = <String, _Paragraph>{};
    for (final block in blocks) {
      var paragraph = next[block.text];
      if (paragraph == null) {
        // 原文不变的段落块沿用已有译文和计时；新出现的先查缓存。
        paragraph =
            _paragraphs[block.text] ??
            _appear(block.text, now, settings, immediate: immediate);
        paragraph.places = [];
        next[block.text] = paragraph;
      }
      paragraph.places.add(block);
    }
    _paragraphs = next;
    // 最新画面不再包含某个批次的任何段落块时，取消该批次。
    for (final batch in List<_Batch>.of(_inflight)) {
      if (!batch.texts.any(next.containsKey)) _cancel(batch);
    }
    _publish();
    _evaluate();
  }

  /// text 为新出现的段落原文，now 为出现时刻，settings 为当前偏好。
  /// 返回该段落；缓存命中时直接带上完整译文。
  _Paragraph _appear(
    String text,
    DateTime now,
    AppSettings settings, {
    required bool immediate,
  }) {
    final paragraph = _Paragraph(text, now, immediate: immediate);
    final hit = _cache.translation(_key(settings, text));
    if (hit != null) {
      paragraph
        ..shown = hit
        ..done = true;
    }
    return paragraph;
  }

  /// notice 为无文字或识别错误的提示。撤去全部段落块并取消在途批次。
  void _clearScreen(String notice) {
    _paragraphs = {};
    _notice = notice;
    clock.cancelSchedule();
    _cancelAll();
    _publish();
  }

  /// 无参数。把当前画面中未命中且已满足发送等待的段落块组成批次并发送。
  void _evaluate() {
    if (_phase != 'running' || _halt != null) {
      clock.cancelSchedule();
      return;
    }
    final settings = _latestSettings!;
    final now = clock.now();
    final ready = <_Paragraph>[];
    DateTime? nextDue;
    var rejected = false;
    for (final paragraph in _paragraphs.values) {
      if (paragraph.done || _sending(paragraph.text)) continue;
      final key = _key(settings, paragraph.text);
      if (_blocked(key)) continue;
      if (paragraph.text.characters.length > inputLimit) {
        _cache.reject(key);
        _lastError = '文字超过 50,000 个字符，未发送翻译请求。';
        rejected = true;
        continue;
      }
      final due = paragraph.immediate
          ? paragraph.observedAt
          : paragraph.observedAt.add(
              LiveRegionSchedule.candidateCoalescingDelay,
            );
      if (now.isBefore(due)) {
        if (nextDue == null || due.isBefore(nextDue)) nextDue = due;
        continue;
      }
      ready.add(paragraph);
    }
    if (rejected) _publish();
    if (ready.isEmpty) {
      if (nextDue == null) {
        clock.cancelSchedule();
      } else {
        clock.schedule(nextDue.difference(now), _evaluate);
      }
      return;
    }
    final limit = providerFor(settings).allowsParallelBatches
        ? LiveRegionSchedule.maxInflightBatches
        : 1;
    // 取消尚未完成的批次仍计入在途数量；任一批次结束后会再次评估。
    if (_inflight.length >= limit) {
      clock.cancelSchedule();
      return;
    }
    final lastStart = _lastBatchStart;
    if (lastStart != null) {
      final allowed = lastStart.add(LiveRegionSchedule.requestStartInterval);
      if (now.isBefore(allowed)) {
        clock.schedule(allowed.difference(now), _evaluate);
        return;
      }
    }
    // 按阅读顺序装满一个批次；需要单独发送的段落块自成一批。
    final items = <_Paragraph>[];
    var chars = 0;
    for (final paragraph in ready) {
      if (paragraph.alone) {
        if (items.isEmpty) items.add(paragraph);
        break;
      }
      final length = paragraph.text.characters.length;
      if (items.isNotEmpty &&
          (items.length >= LiveRegionSchedule.maxBatchBlocks ||
              chars + length > LiveRegionSchedule.maxBatchChars)) {
        break;
      }
      items.add(paragraph);
      chars += length;
    }
    _startBatch(items, settings);
    // 还有待发送的段落块时，到请求开始间隔或最早的发送等待后再评估。
    if (ready.length > items.length) {
      clock.schedule(LiveRegionSchedule.requestStartInterval, _evaluate);
    } else if (nextDue != null) {
      clock.schedule(nextDue.difference(now), _evaluate);
    } else {
      clock.cancelSchedule();
    }
  }

  /// items 为本批次的段落块，settings 为发送时的偏好。
  /// 登记在途批次，识别整批语言后向服务发起一次请求。
  void _startBatch(List<_Paragraph> items, AppSettings latest) {
    // 批次绑定发送时的设置副本，之后的偏好修改不影响本批次。
    final settings = AppSettings.fromMap(latest.toMap());
    final texts = [for (final item in items) item.text];
    final now = clock.now();
    var wait = Duration.zero;
    for (final item in items) {
      final waited = now.difference(item.observedAt);
      if (waited > wait) wait = waited;
    }
    final batch = _Batch(
      texts,
      [for (final text in texts) _key(settings, text)],
      now,
      wait,
    );
    _inflight.add(batch);
    _lastBatchStart = now;
    _publish();
    final epoch = _epoch;
    _beginWork();
    unawaited(() async {
      try {
        final joined = texts.join('\n');
        // 整批识别一次。短段落单独识别经常没有结果，中文会被当成要译成主要语言。
        final detected = await detectLanguage(joined);
        if (epoch != _epoch) return;
        if (batch.cancelled) {
          _inflight.remove(batch);
          return;
        }
        final direction = settings.direction.resolve(
          detected ?? (_containsCjk(joined) ? 'zh-Hans' : null),
        );
        if (direction.detectedLanguage ==
            LanguageDirection.normalize(direction.targetLanguage)) {
          // 已是目标语言时原文即译文，不产生网络请求。
          for (final (index, text) in texts.indexed) {
            batch.partial[index].write(text);
          }
          _complete(batch);
          return;
        }
        batch.subscription = providerFor(settings)
            .translateBatch(
              BatchTranslationRequest(
                texts: texts,
                detectedLanguage: direction.detectedLanguage,
                targetLanguage: direction.targetLanguage,
              ),
              client: _client!,
            )
            .listen(
              (event) => _onEvent(batch, event),
              onError: (Object error) {
                _onEvent(
                  batch,
                  BatchFailure('$error', TranslationFailureKind.transient),
                );
              },
            );
      } catch (_) {
        // 语言识别或创建请求抛错时按临时失败收口：移出在途集合并交给重试逻辑，
        // 不让批次一直占用名额、界面停在「正在翻译」（#116）。
        if (epoch != _epoch) return;
        if (batch.cancelled) {
          _inflight.remove(batch);
          return;
        }
        _fail(batch, '翻译准备失败，将自动重试。', TranslationFailureKind.transient);
      } finally {
        if (epoch == _epoch) _evaluate();
        _endWork(epoch);
      }
    }());
  }

  void _onEvent(_Batch batch, BatchTranslationEvent event) {
    if (batch.cancelled || !_inflight.contains(batch)) return;
    switch (event) {
      case BatchItemUpdate(:final index, :final addition):
        batch.firstAt ??= clock.now();
        batch.partial[index].write(addition);
        final paragraph = _paragraphs[batch.texts[index]];
        // 只有仍在画面上的段落块才显示增量。
        if (paragraph == null || paragraph.done) return;
        paragraph.shown = batch.partial[index].toString();
        _publish();
      case BatchCompleted():
        _complete(batch);
      case BatchFailure(:final message, :final kind):
        _fail(batch, message, kind);
    }
  }

  /// batch 为已完整结束的批次。译文写入缓存；没有译文的段落块单独补发一次。
  void _complete(_Batch batch) {
    for (final (index, text) in batch.texts.indexed) {
      final translation = batch.partial[index].toString().trim();
      final paragraph = _paragraphs[text];
      if (translation.isEmpty) {
        if (paragraph != null && !paragraph.done) paragraph.shown = '';
        if (batch.texts.length == 1) {
          // 单独补发仍没有译文，该段落块不再发送。
          _cache.reject(batch.keys[index]);
          _lastError = '服务未返回该段译文。';
        } else {
          paragraph?.alone = true;
        }
        continue;
      }
      // 已离开画面的段落块也写入缓存，再次出现时直接命中。
      _cache.store(batch.keys[index], translation);
      if (paragraph == null) continue;
      paragraph
        ..shown = translation
        ..done = true;
    }
    _measure(batch, 'completed');
    _finish(batch);
  }

  /// batch 为失败的批次，message/kind 为原因与类别。本批次已收到的译文不作为结果。
  void _fail(_Batch batch, String message, TranslationFailureKind kind) {
    for (final text in batch.texts) {
      final paragraph = _paragraphs[text];
      if (paragraph != null && !paragraph.done) paragraph.shown = '';
    }
    switch (kind) {
      case TranslationFailureKind.service:
        // 本次会话停止发送新批次，待发送的段落块不再处理。
        _halt = message;
      case TranslationFailureKind.paragraph:
        if (batch.texts.length == 1) {
          _cache.reject(batch.keys.single);
          _lastError = message;
        } else {
          // 分不清是哪个段落块引起的，各自单独补发一次。
          for (final text in batch.texts) {
            _paragraphs[text]?.alone = true;
          }
        }
      case TranslationFailureKind.transient:
        batch.keys.forEach(_cache.noteFailure);
        _lastError = message;
    }
    _measure(batch, kind.name);
    _finish(batch);
  }

  /// batch 为已到终态的批次。移出在途集合并重新评估待发送的段落块。
  void _finish(_Batch batch) {
    _inflight.remove(batch);
    unawaited(batch.subscription?.cancel());
    _publish();
    _evaluate();
  }

  /// batch 为要取消的批次。取消完成前仍计入在途数量。
  void _cancel(_Batch batch) {
    if (batch.cancelled) return;
    batch.cancelled = true;
    _measure(batch, 'cancelled');
    final subscription = batch.subscription;
    // 语言识别尚未返回时没有订阅；识别返回后见到取消标记即移出在途集合。
    if (subscription == null) return;
    final epoch = _epoch;
    _beginWork();
    unawaited(
      subscription.cancel().whenComplete(() {
        if (epoch != _epoch) return;
        _inflight.remove(batch);
        _evaluate();
        _endWork(epoch);
      }),
    );
  }

  /// 无参数。取消全部在途批次。
  void _cancelAll() {
    for (final batch in List<_Batch>.of(_inflight)) {
      _cancel(batch);
    }
  }

  /// 无参数。会话结束时释放全部工作：停止计时、取消批次、关闭连接并清空缓存。
  void _release() {
    clock.cancelSchedule();
    for (final batch in _inflight) {
      batch.cancelled = true;
      unawaited(batch.subscription?.cancel());
    }
    _inflight.clear();
    _client?.close(force: true);
    _client = null;
    _cache.clear();
  }

  /// batch 为到达终态的批次，outcome 为 completed、cancelled 或失败类别名。
  /// 记下一条计时，随下一次快照发布。
  void _measure(_Batch batch, String outcome) {
    final now = clock.now();
    _metrics.add({
      'blocks': batch.texts.length,
      'chars': batch.texts.fold<int>(0, (sum, text) => sum + text.length),
      'waitMs': batch.wait.inMilliseconds,
      'firstMs':
          batch.firstAt?.difference(batch.startedAt).inMilliseconds ?? -1,
      'totalMs': now.difference(batch.startedAt).inMilliseconds,
      'inflight': _inflight.length,
      'outcome': outcome,
    });
  }

  void _beginWork() => _pending += 1;

  void _endWork(int epoch) {
    if (epoch != _epoch) return;
    _pending -= 1;
    if (_pending > 0) return;
    final waiters = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  /// settings 为偏好，text 为段落原文；返回“服务＋语言方向＋段落原文”的缓存键。
  String _key(AppSettings settings, String text) {
    final direction = settings.direction;
    return '${settings.defaultServiceId}\n${direction.primaryCode}\n'
        '${direction.secondaryCode ?? ''}\n$text';
  }

  /// key 为段落键；返回该段落是否已判定不再发送或已用尽临时错误的重试次数。
  bool _blocked(String key) =>
      _cache.rejected(key) ||
      _cache.failures(key) > LiveRegionSchedule.transientRetryLimit;

  /// text 为段落原文；返回它是否已在某个未取消的在途批次中。
  bool _sending(String text) => _inflight.any(
    (batch) => !batch.cancelled && batch.texts.contains(text),
  );

  /// text 含汉字时，语言识别失败也按中文处理，避免再译成中文。
  bool _containsCjk(String text) => RegExp(r'[㐀-鿿]').hasMatch(text);

  /// 无参数；返回控制条显示的状态。
  String _status() {
    if (_halt != null) return _halt!;
    if (_paragraphs.isEmpty) return _notice;
    if (_inflight.any((batch) => !batch.cancelled)) return '正在翻译';
    final settings = _latestSettings!;
    final unfinished = [
      for (final paragraph in _paragraphs.values)
        if (!paragraph.done) paragraph,
    ];
    if (unfinished.isEmpty) return '已完成';
    // 剩下的段落块都不再发送时显示最近的错误，否则仍在等待发送。
    final waiting = unfinished.any(
      (paragraph) => !_blocked(_key(settings, paragraph.text)),
    );
    return waiting ? '等待翻译' : _lastError ?? '等待翻译';
  }

  /// 无参数。运行中且译文已归属到有坐标的段落块时才返回盖层。
  List<Map<String, Object>> _overlayMaps() {
    if (_phase != 'running') return const [];
    final maps = <Map<String, Object>>[];
    for (final paragraph in _paragraphs.values) {
      final text = paragraph.shown;
      if (text.isEmpty || text.trim() == paragraph.text.trim()) continue;
      for (final place in paragraph.places) {
        if (!place.placeable) continue;
        maps.add({
          'text': text,
          'x': place.x!,
          'y': place.y!,
          'width': place.width!,
          'height': place.height!,
        });
      }
    }
    return maps;
  }

  LiveRegionView _publish() {
    final metrics = _metrics;
    _metrics = [];
    view = LiveRegionView(
      generation: _generation,
      phase: _phase,
      source: _paragraphs.keys.join('\n'),
      translation: [
        for (final paragraph in _paragraphs.values)
          if (paragraph.shown.isNotEmpty) paragraph.shown,
      ].join('\n'),
      status: _status(),
      banner: _banner,
      overlays: _overlayMaps(),
      metrics: metrics,
    );
    onView?.call(view);
    return view;
  }
}
