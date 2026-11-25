import 'package:equilibra/screens/auth_screen.dart';
import 'package:equilibra/services/auth_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAuthService implements AuthService {
  String? email;
  String? password;

  @override
  Future<void> register({
    required String email,
    required String password,
  }) async {
    this.email = email;
    this.password = password;
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    this.email = email;
    this.password = password;
  }
}

void main() {
  testWidgets('valida e inicia sesión con correo y contraseña', (tester) async {
    final auth = FakeAuthService();
    await tester.pumpWidget(MaterialApp(home: AuthScreen(authService: auth)));

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Correo'),
      'persona@equilibra.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Contraseña'),
      'secreto123',
    );
    await tester.tap(find.text('Iniciar sesión'));
    await tester.pump();

    expect(auth.email, 'persona@equilibra.com');
    expect(auth.password, 'secreto123');
    expect(tester.takeException(), isNull);
  });
}
