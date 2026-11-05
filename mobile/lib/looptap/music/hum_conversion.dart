import 'package:dio/dio.dart';

/// One attempt to convert a recording owned by the hum modal. A retry gets a
/// fresh request/token but the same file; closing cancels any outstanding work.
class HumConversionRequest {
  HumConversionRequest(this.audioPath);

  final String audioPath;
  final CancelToken cancelToken = CancelToken();

  bool get cancelled => cancelToken.isCancelled;

  void cancel() => cancelToken.cancel('hum modal closed');
}

enum HumConversionStatus { success, failure, cancelled }

/// Returning from a callback is not proof that notes were added. The modal
/// shows success only for [HumConversionStatus.success].
class HumConversionResult {
  const HumConversionResult.success()
    : status = HumConversionStatus.success,
      message = null;

  const HumConversionResult.failure([this.message])
    : status = HumConversionStatus.failure;

  const HumConversionResult.cancelled()
    : status = HumConversionStatus.cancelled,
      message = null;

  final HumConversionStatus status;
  final String? message;
}
