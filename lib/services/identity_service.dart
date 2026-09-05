import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

enum SignInProvider { google, apple }

extension SignInProviderName on SignInProvider {
  String get wireName => this == SignInProvider.google ? 'google' : 'apple';

  String get label =>
      this == SignInProvider.google ? 'Continue with Google' : 'Continue with Apple';
}

/// Raised when sign-in could not produce a token. `cancelled` is the ordinary
/// case of the user backing out, and the UI stays quiet for it.
class SignInException implements Exception {
  SignInException(this.message, {this.cancelled = false});

  final String message;
  final bool cancelled;

  @override
  String toString() => message;
}

/// Obtains a signed identity token from Google or Apple.
///
/// The token goes straight to our server, which verifies it against the
/// provider's public keys. Nothing here is trusted on its own.
class IdentityService {
  /// OAuth client ids, supplied at build time so they are not baked into the
  /// repository:
  /// `--dart-define=GOOGLE_CLIENT_ID=... --dart-define=GOOGLE_SERVER_CLIENT_ID=...`
  static const googleClientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
  static const googleServerClientId =
      String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  bool _googleReady = false;

  /// True when the platform can offer this provider at all. Apple only makes
  /// sense on Apple platforms, and Google needs a configured client id.
  Future<bool> supports(SignInProvider provider) async {
    switch (provider) {
      case SignInProvider.apple:
        if (kIsWeb) return false;
        return defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS;
      case SignInProvider.google:
        return googleServerClientId.isNotEmpty || googleClientId.isNotEmpty;
    }
  }

  Future<String> tokenFor(SignInProvider provider) =>
      provider == SignInProvider.google ? _google() : _apple();

  Future<String> _google() async {
    if (googleClientId.isEmpty && googleServerClientId.isEmpty) {
      throw SignInException(
        'Google sign-in is not configured in this build.',
      );
    }

    try {
      if (!_googleReady) {
        await GoogleSignIn.instance.initialize(
          clientId: googleClientId.isEmpty ? null : googleClientId,
          serverClientId:
              googleServerClientId.isEmpty ? null : googleServerClientId,
        );
        _googleReady = true;
      }

      if (!GoogleSignIn.instance.supportsAuthenticate()) {
        // Web needs the Google-rendered button rather than our own.
        throw SignInException(
          'Google sign-in is not available on this platform.',
        );
      }

      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw SignInException('Google did not return a sign-in token.');
      }
      return idToken;
    } on GoogleSignInException catch (e) {
      throw SignInException(
        'Google sign-in failed.',
        cancelled: e.code == GoogleSignInExceptionCode.canceled,
      );
    } on SignInException {
      rethrow;
    } catch (e) {
      throw SignInException('Google sign-in failed.');
    }
  }

  Future<String> _apple() async {
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email],
      );
      final token = credential.identityToken;
      if (token == null || token.isEmpty) {
        throw SignInException('Apple did not return a sign-in token.');
      }
      return token;
    } on SignInWithAppleAuthorizationException catch (e) {
      throw SignInException(
        'Apple sign-in failed.',
        cancelled: e.code == AuthorizationErrorCode.canceled,
      );
    } on SignInException {
      rethrow;
    } catch (e) {
      throw SignInException('Apple sign-in failed.');
    }
  }
}
