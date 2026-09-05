import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:in_app_purchase/in_app_purchase.dart';

/// What the store told us about one purchase attempt, translated into terms
/// the app cares about.
enum PurchaseOutcome { pending, credited, cancelled, failed }

class PurchaseEvent {
  const PurchaseEvent(this.outcome, {this.message, this.credited = 0});

  final PurchaseOutcome outcome;
  final String? message;

  /// Credits the server actually granted. Zero for a receipt it had already
  /// processed, which is the normal case when restoring on a new device.
  final int credited;
}

/// Hands a store receipt to the server and reports whether it was credited.
///
/// Returning false leaves the purchase uncompleted so the store replays it on
/// the next launch, which is what should happen when our server is unreachable.
typedef PurchaseVerifier = Future<int?> Function({
  required String productId,
  required String purchaseToken,
  required bool isSubscription,
});

/// Wraps the platform billing clients.
///
/// The store is only ever the source of a receipt. It never decides how many
/// credits a pack is worth - the server does that from its own catalogue, so a
/// tampered client cannot mint credits.
class PurchaseService {
  PurchaseService({InAppPurchase? store, bool? supported})
      : _store = store ?? InAppPurchase.instance,
        _supported = supported ??
            (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  final InAppPurchase _store;

  /// Overridden in tests, where there is no billing client to talk to.
  final bool _supported;

  StreamSubscription<List<PurchaseDetails>>? _subscription;
  final _events = StreamController<PurchaseEvent>.broadcast();
  PurchaseVerifier? _verify;

  /// Details fetched from the store, keyed by product id. Prices here are
  /// localised by the store and are what the user is actually charged.
  final Map<String, ProductDetails> _details = {};

  Stream<PurchaseEvent> get events => _events.stream;

  ProductDetails? detailsFor(String productId) => _details[productId];

  /// True only where a store exists. Desktop and web have no billing client,
  /// so the paywall stays inert there rather than throwing.
  bool get supported => _supported;

  bool _started = false;

  /// Product ids the stores treat as auto-renewable subscriptions. They are
  /// bought and completed differently from consumable packs, and getting that
  /// backwards either fails outright or consumes a subscription.
  Set<String> _subscriptionIds = const {};

  bool isSubscription(String productId) => _subscriptionIds.contains(productId);

  /// Starts listening before any purchase is made. The stream also replays
  /// purchases that completed while the app was closed, which is how a payment
  /// interrupted by a crash still gets credited.
  Future<void> start({
    required PurchaseVerifier verify,
    required Set<String> productIds,
    Set<String> subscriptionIds = const {},
  }) async {
    if (_started || !supported) return;
    _started = true;
    _verify = verify;
    _subscriptionIds = subscriptionIds;

    if (!await _store.isAvailable()) return;

    _subscription = _store.purchaseStream.listen(
      _onPurchases,
      onError: (Object e) => _emit(
        PurchaseOutcome.failed,
        message: 'The store connection failed.',
      ),
    );

    await loadProducts(productIds);

    // Picks up anything bought but never credited, including purchases made
    // on another device with the same store account.
    await _store.restorePurchases();
  }

  Future<void> loadProducts(Set<String> productIds) async {
    if (!supported || productIds.isEmpty) return;
    try {
      final response = await _store.queryProductDetails(productIds);
      for (final product in response.productDetails) {
        _details[product.id] = product;
      }
    } catch (_) {
      // Leaves _details empty; the UI falls back to the server's own prices.
    }
  }

  /// Opens the store's purchase sheet. The result arrives on [events], not
  /// here, because the store may answer minutes later.
  Future<void> buy(String productId) async {
    if (!supported) {
      _emit(
        PurchaseOutcome.failed,
        message: 'Purchases are not available on this device.',
      );
      return;
    }

    final product = _details[productId];
    if (product == null) {
      _emit(
        PurchaseOutcome.failed,
        message: 'That is not available from the store right now.',
      );
      return;
    }

    try {
      final param = PurchaseParam(productDetails: product);
      if (isSubscription(productId)) {
        // A subscription is not consumable. Buying it as one is rejected by
        // Play, and completing it as one would end the subscription.
        await _store.buyNonConsumable(purchaseParam: param);
      } else {
        // Credit packs are consumable: the same pack must be buyable again.
        await _store.buyConsumable(purchaseParam: param);
      }
    } catch (_) {
      _emit(PurchaseOutcome.failed, message: 'The store could not start the purchase.');
    }
  }

  Future<void> restore() async {
    if (!supported) return;
    try {
      await _store.restorePurchases();
    } catch (_) {
      _emit(PurchaseOutcome.failed, message: 'Could not restore purchases.');
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      switch (purchase.status) {
        case PurchaseStatus.pending:
          _emit(PurchaseOutcome.pending);

        case PurchaseStatus.canceled:
          _emit(PurchaseOutcome.cancelled);
          await _finish(purchase);

        case PurchaseStatus.error:
          _emit(
            PurchaseOutcome.failed,
            message: purchase.error?.message ?? 'The purchase did not go through.',
          );
          await _finish(purchase);

        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _credit(purchase);
      }
    }
  }

  Future<void> _credit(PurchaseDetails purchase) async {
    final verify = _verify;
    if (verify == null) return;

    final credited = await verify(
      productId: purchase.productID,
      purchaseToken: _receiptOf(purchase),
      isSubscription: isSubscription(purchase.productID),
    );

    if (credited == null) {
      // The server never confirmed. Leaving the purchase uncompleted means the
      // store hands it back on the next launch rather than the user losing it.
      _emit(
        PurchaseOutcome.failed,
        message: 'Payment taken, but crediting failed. It will be added the '
            'next time you open the app.',
      );
      return;
    }

    _emit(PurchaseOutcome.credited, credited: credited);
    await _finish(purchase);
  }

  /// Only safe once the server has the receipt: on Android this consumes the
  /// purchase, and an unconsumed one is auto-refunded after three days.
  Future<void> _finish(PurchaseDetails purchase) async {
    if (purchase.pendingCompletePurchase) {
      await _store.completePurchase(purchase);
    }
  }

  /// The two stores are verified in different ways, so they need different
  /// halves of the receipt: Play checks a purchase token, while our App Store
  /// check looks the transaction up by id.
  String _receiptOf(PurchaseDetails purchase) {
    if (!kIsWeb && Platform.isIOS) {
      return purchase.purchaseID ?? purchase.verificationData.serverVerificationData;
    }
    return purchase.verificationData.serverVerificationData;
  }

  void _emit(PurchaseOutcome outcome, {String? message, int credited = 0}) {
    if (_events.isClosed) return;
    _events.add(PurchaseEvent(outcome, message: message, credited: credited));
  }

  void dispose() {
    _subscription?.cancel();
    _events.close();
  }
}
