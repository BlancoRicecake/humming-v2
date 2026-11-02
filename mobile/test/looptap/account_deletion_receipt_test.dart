import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/state/loop_store.dart';

void main() {
  test('accepted deletion remains pending rather than completed', () {
    expect(AccountDeletionReceipt.fromResponse(202, {'status': 'deletion_pending'}), AccountDeletionReceipt.pending);
    expect(AccountDeletionReceipt.fromResponse(204, null), AccountDeletionReceipt.complete);
    expect(AccountDeletionReceipt.fromResponse(200, null), AccountDeletionReceipt.complete);
  });

  test('an unknown accepted response or failed request is not a deletion receipt', () {
    for (final body in [null, 'ok', {'status': 'unknown'}]) {
      expect(AccountDeletionReceipt.fromResponse(202, body), AccountDeletionReceipt.rejected);
    }
    expect(AccountDeletionReceipt.fromResponse(503, {'status': 'deletion_pending'}), AccountDeletionReceipt.rejected);
  });
}
