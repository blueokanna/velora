import '../src/rust/api/book_source.dart' as source_api;
import '../src/rust/api/source_runtime.dart' as runtime_api;
import '../state/sources.dart';

class SourceRequestFailure implements Exception {
  const SourceRequestFailure(this.info);

  final runtime_api.SourceFailureInfo info;

  bool get isCancelled => info.kind == runtime_api.FailureKind.cancelled;

  String get userMessage {
    final retryAfter = info.retryAfterMs;
    final retryHint = retryAfter == null
        ? ''
        : '，约 ${_formatDuration(retryAfter)} 后可重试';
    return switch (info.kind) {
      runtime_api.FailureKind.networkTransient => '网络暂时不可用，请稍后重试',
      runtime_api.FailureKind.rateLimited => '书源请求过于频繁$retryHint',
      runtime_api.FailureKind.authDenied => '书源需要授权或已拒绝访问',
      runtime_api.FailureKind.resourceGone => '该资源已下架或链接失效',
      runtime_api.FailureKind.parserBroken => '书源解析规则已失效',
      runtime_api.FailureKind.invalidContent => '书源返回的正文内容无效',
      runtime_api.FailureKind.invalidRule => '书源配置或规则无效',
      runtime_api.FailureKind.httpRejected => '源站拒绝了这次请求',
      runtime_api.FailureKind.circuitOpen => '书源暂时不可用$retryHint',
      runtime_api.FailureKind.cancelled => '请求已取消',
    };
  }

  @override
  String toString() => userMessage;

  static String _formatDuration(BigInt milliseconds) {
    final seconds = (milliseconds ~/ BigInt.from(1000)).toInt();
    if (seconds < 60) return '${seconds.clamp(1, 59)} 秒';
    return '${(seconds / 60).ceil()} 分钟';
  }
}

class SourceAdapterService {
  const SourceAdapterService();

  static int _requestSequence = 0;

  String createRequestId(String operation) {
    _requestSequence = (_requestSequence + 1) & 0x7fffffff;
    return '$operation-${DateTime.now().microsecondsSinceEpoch}-$_requestSequence';
  }

  bool cancel(String requestId) =>
      runtime_api.cancelSourceRequest(requestId: requestId);

  Future<List<source_api.SearchResult>> search(
    BookSourceModel source,
    String keyword, {
    required String requestId,
  }) async {
    final outcome = await source_api.sourceSearchReliable(
      sourceJson: source.toJsonString(),
      keyword: keyword,
      requestId: requestId,
    );
    _throwFailure(outcome.failure);
    return outcome.results;
  }

  Future<source_api.BookDetail> bookDetail(
    String sourceJson,
    String bookUrl, {
    required String requestId,
  }) async {
    final outcome = await source_api.sourceBookDetailReliable(
      sourceJson: sourceJson,
      bookUrl: bookUrl,
      requestId: requestId,
    );
    _throwFailure(outcome.failure);
    final detail = outcome.detail;
    if (detail == null) {
      throw StateError('书源详情响应缺少数据');
    }
    return detail;
  }

  Future<List<source_api.TocEntry>> toc(
    String sourceJson,
    String tocUrl, {
    required String requestId,
  }) async {
    final outcome = await source_api.sourceTocReliable(
      sourceJson: sourceJson,
      tocUrl: tocUrl,
      requestId: requestId,
    );
    _throwFailure(outcome.failure);
    return outcome.entries;
  }

  Future<String> chapterContent(
    String sourceJson,
    String chapterUrl, {
    required String requestId,
  }) async {
    final outcome = await source_api.sourceChapterContentReliable(
      sourceJson: sourceJson,
      chapterUrl: chapterUrl,
      requestId: requestId,
    );
    _throwFailure(outcome.failure);
    return outcome.content;
  }

  List<runtime_api.SourceHealthSnapshot> healthSnapshots() =>
      runtime_api.sourceHealthSnapshots();

  List<runtime_api.SourceObservation> recentObservations({
    String? sourceId,
    int limit = 100,
  }) => runtime_api.sourceRecentObservations(
    sourceId: sourceId,
    limit: limit.clamp(1, 1000),
  );

  static void _throwFailure(runtime_api.SourceFailureInfo? failure) {
    if (failure != null) throw SourceRequestFailure(failure);
  }
}
