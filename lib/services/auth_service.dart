import 'package:firebase_auth/firebase_auth.dart';

abstract interface class AuthService {
  Future<void> signIn({required String email, required String password});

  Future<void> register({required String email, required String password});
}

class FirebaseAuthService implements AuthService {
  // El parámetro es opcional con nombre; un campo privado no puede declararse
  // como formal inicializador (`this._auth`) en parámetros con nombre.
  // ignore: prefer_initializing_formals
  FirebaseAuthService({FirebaseAuth? auth}) : _auth = auth;

  /// Se resuelve de forma diferida: construir el servicio antes de que
  /// Firebase Core esté listo ya no lanza `CoreNotInitializedException`.
  FirebaseAuth? _auth;

  FirebaseAuth get _instance => _auth ??= FirebaseAuth.instance;

  @override
  Future<void> signIn({required String email, required String password}) =>
      _instance.signInWithEmailAndPassword(email: email, password: password);

  @override
  Future<void> register({required String email, required String password}) =>
      _instance.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
}

String authErrorMessage(Object error) {
  if (error is FirebaseAuthException) {
    return switch (error.code) {
      'invalid-email' => 'El correo no es válido.',
      'invalid-credential' ||
      'wrong-password' ||
      'user-not-found' => 'Correo o contraseña incorrectos.',
      'email-already-in-use' => 'Ese correo ya está registrado.',
      'weak-password' => 'Usa una contraseña más segura.',
      'too-many-requests' => 'Espera un momento e inténtalo de nuevo.',
      'network-request-failed' => 'Revisa tu conexión a internet.',
      _ => 'No se pudo completar la operación.',
    };
  }
  return 'Ocurrió un error. Inténtalo de nuevo.';
}
