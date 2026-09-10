import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/account.dart';
import '../models/check_request.dart';
import '../models/check_result.dart';
import 'anthropic_client.dart' show ApiException, CheckProgress;

/// Result of a metered check: the report plus what it cost.
class MeteredCheck {
  const MeteredCheck({
    required this.result,
    required this.balance,
    required this.creditsSpent,
  });

  final CheckResult result;
  final int balance;
  final int creditsSpent;
}

/// Outcome of binding a sign-in to an account.
class LinkResult {
  const LinkResult({
    required this.token,
    required this.balance,
    required this.merged,
    required this.carriedCredits,
    required this.identity,
  });

  /// Always store this: after a merge it addresses a different account.
  final String token;
  final int balance;

  /// True when the device was moved onto an account that already existed.
  final bool merged;

  /// Credits carried over from the anonymous account during a merge.
  final int carriedCredits;

  final LinkedIdentity? identity;
}

/// What the server did with a store receipt.
class PurchaseResult {
  const PurchaseResult({
    required this.balance,
    required this.credited,
    required this.alreadyProcessed,
  });

  final int balance;

  /// Credits granted by this call. Zero when the receipt had already been
  /// credited, which is the normal outcome of restoring purchases.
  final int credited;

  final bool alreadyProcessed;
}

/// What the server did with a subscription receipt.
class SubscriptionResult {
  const SubscriptionResult({
    required this.balance,
    required this.granted,
    required this.entitlement,
  });

  final int balance;

  /// Credits granted by this call. Zero when this month's allowance had
  /// already been paid out, which is the normal outcome of restoring.
  final int granted;

  final Entitlement entitlement;
}

/// Raised when the balance cannot cover a check, so the UI can open the
/// paywall instead of showing a generic error.
class OutOfCreditsException extends ApiException {
  OutOfCreditsException(super.message, {required this.balance, required this.required_});

  final int balance;
  final int required_;
}

/// Talks to the Writing Checker server, which holds the API key and the
/// credit balance.
///
/// The app never sees an Anthropic key in this mode. It authenticates with a
/// device token, and the server decides what each check costs.
class BackendClient {
  BackendClient({String? baseUrl, http.Client? httpClient})
      : baseUrl = baseUrl ?? defaultBaseUrl,
        _http = httpClient ?? http.Client();

  /// Override at build time:
  /// `flutter run --dart-define=BACKEND_URL=https://api.example.com`
  static const defaultBaseUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'http://localhost:8787',
  );

  final String baseUrl;
  final http.Client _http;
  bool _cancelled = false;

  void cancel() => _cancelled = true;
  void dispose() => _http.close();

  Uri _uri(String path) => Uri.parse('$baseUrl/v1$path');

  Map<String, String> _headers([String? token]) => {
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      };

  /// Trades the locally generated install id for a device token. Safe to call
  /// on every launch; the server grants the free trial only once.
  Future<Account> registerDevice({
    required String installId,
    required String platform,
  }) async {
    final response = await _post(
      _uri('/devices'),
      headers: _headers(),
      body: {'installId': installId, 'platform': platform},
    );
    final json = _decode(response);
    return Account.fromJson(json);
  }

  /// Refreshes balance and catalogue.
  Future<Account> fetchAccount(String token) async {
    final http.Response response;
    try {
      response = await _http
          .get(_uri('/me'), headers: _headers(token))
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      throw ApiException('Could not reach the server. Check your connection.');
    }
    final json = _decode(response);
    return Account.fromJson(json, token: token);
  }

  /// Binds a Google or Apple sign-in to this device's account.
  ///
  /// The returned token replaces the current one: after a merge it addresses
  /// a different account, the one that actually holds the paid-for credits.
  Future<LinkResult> linkIdentity({
    required String token,
    required String provider,
    required String idToken,
  }) async {
    final response = await _post(
      _uri('/auth/link'),
      headers: _headers(token),
      body: {'provider': provider, 'idToken': idToken},
    );
    final json = _decode(response);

    return LinkResult(
      token: (json['token'] ?? token).toString(),
      balance: (json['balance'] as num?)?.toInt() ?? 0,
      merged: json['merged'] == true,
      carriedCredits: (json['carriedCredits'] as num?)?.toInt() ?? 0,
      identity: LinkedIdentity.fromJson(
        (json['identity'] as Map?)?.cast<String, dynamic>(),
      ),
    );
  }

  /// Deletes the account on the server. Both stores require an app with
  /// sign-in to offer this from inside the app, not only on a website.
  Future<void> deleteAccount(String token) async {
    final http.Response response;
    try {
      response = await _http
          .delete(_uri('/me'), headers: _headers(token))
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw ApiException('Could not reach the server. Check your connection.');
    }
    if (response.statusCode != 200) {
      throw _errorFor(response.statusCode, response.body);
    }
  }

  /// Sends a verified store purchase for crediting. Idempotent server-side, so
  /// retrying after a dropped connection is safe.
  Future<PurchaseResult> submitPurchase({
    required String token,
    required String platform,
    required String productId,
    required String purchaseToken,
  }) async {
    final response = await _post(
      _uri('/purchases'),
      headers: _headers(token),
      body: {
        'platform': platform,
        'productId': productId,
        'token': purchaseToken,
      },
    );
    final json = _decode(response);
    return PurchaseResult(
      balance: (json['balance'] as num?)?.toInt() ?? 0,
      credited: (json['credited'] as num?)?.toInt() ?? 0,
      alreadyProcessed: json['alreadyProcessed'] == true,
    );
  }

  /// Activates or restores a subscription.
  ///
  /// The same call serves both: a fresh purchase and a restore on a new device
  /// are indistinguishable to the server, which asks the store what is owned
  /// rather than trusting either. Safe to retry.
  Future<SubscriptionResult> submitSubscription({
    required String token,
    required String platform,
    required String productId,
    required String purchaseToken,
  }) async {
    final response = await _post(
      _uri('/subscriptions'),
      headers: _headers(token),
      body: {
        'platform': platform,
        'productId': productId,
        'token': purchaseToken,
      },
    );
    final json = _decode(response);
    return SubscriptionResult(
      balance: (json['balance'] as num?)?.toInt() ?? 0,
      granted: (json['granted'] as num?)?.toInt() ?? 0,
      entitlement: (json['entitlement'] as Map?) == null
          ? Entitlement.free
          : Entitlement.fromJson(
              (json['entitlement'] as Map).cast<String, dynamic>(),
            ),
    );
  }

  /// Runs a check. The server streams progress and then the finished report.
  Future<MeteredCheck> check(
    CheckRequest request, {
    required String token,
    required String tierId,
    void Function(CheckProgress)? onProgress,
  }) async {
    _cancelled = false;

    final attachment = request.attachment;
    final payload = <String, dynamic>{
      'text': request.text,
      'tier': tierId,
      'learningLanguage': request.learningLanguage,
      'nativeLanguage': request.nativeLanguage,
      if (attachment != null)
        'attachment': {
          'kind': attachment.kind == AttachmentKind.pdf ? 'pdf' : 'image',
          'mediaType': attachment.mediaType,
          'data': attachment.base64Data,
        },
    };

    final streamedRequest = http.Request('POST', _uri('/check'))
      ..headers.addAll(_headers(token))
      ..body = jsonEncode(payload);
    streamedRequest.encoding = utf8;

    http.StreamedResponse response;
    try {
      response =
          await _http.send(streamedRequest).timeout(const Duration(minutes: 5));
    } on TimeoutException {
      throw ApiException('The check took too long. Try a shorter text.');
    } catch (_) {
      throw ApiException('Could not reach the server. Check your connection.');
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw _errorFor(response.statusCode, body);
    }

    // Server-sent events: an `event:` line names the type, `data:` carries JSON.
    String? eventName;
    Map<String, dynamic>? resultEvent;
    Map<String, dynamic>? errorEvent;

    final lines =
        response.stream.transform(utf8.decoder).transform(const LineSplitter());

    await for (final line in lines) {
      if (_cancelled) break;

      if (line.startsWith('event:')) {
        eventName = line.substring(6).trim();
        continue;
      }
      if (!line.startsWith('data:')) continue;

      final raw = line.substring(5).trim();
      if (raw.isEmpty) continue;

      Map<String, dynamic> data;
      try {
        data = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }

      switch (eventName) {
        case 'progress':
          onProgress?.call(CheckProgress(
            charsReceived: (data['chars'] as num?)?.toInt() ?? 0,
            stage: data['stage'] == 'writing'
                ? 'Writing feedback'
                : 'Marking your text',
          ));
        case 'result':
          resultEvent = data;
        case 'error':
          errorEvent = data;
      }
    }

    if (_cancelled) throw ApiException('Check cancelled.');

    if (errorEvent != null) {
      throw ApiException((errorEvent['error'] ?? 'Marking failed.').toString());
    }
    if (resultEvent == null) {
      throw ApiException('The connection dropped before the report arrived.');
    }

    final reportJson = (resultEvent['report'] as Map).cast<String, dynamic>();
    final result = CheckResult.fromJson(reportJson, modelId: '');
    if (request.text.trim().isNotEmpty) {
      result.locateSpans(request.text);
    }

    return MeteredCheck(
      result: result,
      balance: (resultEvent['balance'] as num?)?.toInt() ?? 0,
      creditsSpent: (resultEvent['creditsSpent'] as num?)?.toInt() ?? 0,
    );
  }

  Future<http.Response> _post(
    Uri uri, {
    required Map<String, String> headers,
    required Map<String, dynamic> body,
  }) async {
    try {
      return await _http
          .post(uri, headers: headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw ApiException('The server took too long to answer.');
    } catch (_) {
      throw ApiException('Could not reach the server. Check your connection.');
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw _errorFor(response.statusCode, response.body);
    }
    if (response.statusCode != 200) {
      throw _errorFor(response.statusCode, response.body);
    }
    return json;
  }

  ApiException _errorFor(int status, String body) {
    String message = 'Something went wrong (HTTP $status).';
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
      message = (json['error'] ?? message).toString();
    } catch (_) {
      // Non-JSON body: keep the generic message rather than showing HTML.
    }

    if (status == 402 || json?['code'] == 'insufficient_credits') {
      return OutOfCreditsException(
        message,
        balance: (json?['balance'] as num?)?.toInt() ?? 0,
        required_: (json?['required'] as num?)?.toInt() ?? 0,
      );
    }

    return ApiException(message, statusCode: status, type: json?['code'] as String?);
  }
}
