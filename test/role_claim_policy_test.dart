import 'package:equilibra/models/role_claim_result.dart';
import 'package:equilibra/services/role_claim_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RoleClaimPolicy', () {
    const policy = RoleClaimPolicy();

    test('aplica backoff exponencial con tope', () {
      expect(policy.backoffFor(0), Duration.zero);
      expect(policy.backoffFor(1), const Duration(milliseconds: 600));
      expect(policy.backoffFor(2), const Duration(milliseconds: 1200));
      expect(policy.backoffFor(3), const Duration(milliseconds: 2400));
      expect(policy.backoffFor(4), const Duration(milliseconds: 2500));
      expect(policy.backoffFor(50), policy.maxBackoff);
    });

    test('el presupuesto restante nunca es negativo', () {
      expect(policy.remainingBudget(Duration.zero), policy.overallTimeout);
      expect(
        policy.remainingBudget(const Duration(seconds: 5)),
        policy.overallTimeout - const Duration(seconds: 5),
      );
      expect(policy.remainingBudget(const Duration(minutes: 1)), Duration.zero);
    });

    test('la envolvente global cubre autenticación, intentos y presencia', () {
      expect(policy.totalBudget, greaterThan(policy.overallTimeout));
      expect(
        policy.totalBudget,
        policy.authTimeout +
            policy.overallTimeout +
            policy.presenceTimeout +
            const Duration(seconds: 2),
      );
    });
  });

  group('RoleClaimResult', () {
    test('ocupado y revocado son resultados definitivos', () {
      const occupied = RoleClaimResult.occupied(
        terminalId: 't2',
        deviceName: 'Teléfono 2',
      );
      expect(occupied.claimed, isFalse);
      expect(occupied.occupied, isTrue);
      expect(occupied.revoked, isFalse);
      expect(occupied.failed, isFalse);
      expect(occupied.definitive, isTrue);

      const revoked = RoleClaimResult.revoked();
      expect(revoked.claimed, isFalse);
      expect(revoked.revoked, isTrue);
      expect(revoked.failed, isFalse);
      expect(revoked.definitive, isTrue);
    });

    test('un fallo de red no se interpreta como rol ocupado', () {
      const failed = RoleClaimResult.failed(
        RoleClaimFailure.offline,
        detail: 'RTDB sin conexión',
      );
      expect(failed.claimed, isFalse);
      expect(failed.occupied, isFalse);
      expect(failed.failed, isTrue);
      expect(failed.definitive, isFalse);
      expect(failed.failureLabel, 'sin conexión con Firebase');
    });

    test('sólo los fallos de infraestructura se reintentan', () {
      expect(RoleClaimFailure.offline.isRetryable, isTrue);
      expect(RoleClaimFailure.timeout.isRetryable, isTrue);
      expect(RoleClaimFailure.unknown.isRetryable, isTrue);
      expect(RoleClaimFailure.unauthenticated.isRetryable, isFalse);
      expect(RoleClaimFailure.permissionDenied.isRetryable, isFalse);
    });
  });
}
