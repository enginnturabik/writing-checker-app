import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';
import 'package:writing_checker/services/purchase_service.dart';

/// Stands in for the platform billing client.
class FakeStore implements InAppPurchase {
  final _controller = StreamController<List<PurchaseDetails>>.broadcast();

  bool available = true;
  final List<PurchaseDetails> completed = [];
  int buyCalls = 0;
  int restoreCalls = 0;

  void emit(List<PurchaseDetails> purchases) => _controller.add(purchases);

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _controller.stream;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<ProductDetailsResponse> queryProductDetails(
    Set<String> identifiers,
  ) async =>
      ProductDetailsResponse(
        productDetails: [
          for (final id in identifiers)
            ProductDetails(
              id: id,
              title: id,
              description: id,
              price: '₺34,99',
              rawPrice: 34.99,
              currencyCode: 'TRY',
            ),
        ],
        notFoundIDs: const [],
      );

  @override
  Future<bool> buyConsumable({
    required PurchaseParam purchaseParam,
    bool autoConsume = true,
  }) async {
    buyCalls++;
    return true;
  }

  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async =>
      true;

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    completed.add(purchase);
  }

  @override
  Future<void> restorePurchases({String? applicationUserName}) async {
    restoreCalls++;
  }

  @override
  Future<String> countryCode() async => 'TR';

  @override
  T getPlatformAddition<T extends InAppPurchasePlatformAddition?>() =>
      throw UnimplementedError();
}

PurchaseDetails receipt({
  String productId = 'credits_12',
  String token = 'play-token-1',
  PurchaseStatus status = PurchaseStatus.purchased,
  String? purchaseId = 'txn-1',
}) =>
    PurchaseDetails(
      productID: productId,
      purchaseID: purchaseId,
      verificationData: PurchaseVerificationData(
        localVerificationData: token,
        serverVerificationData: token,
        source: 'google_play',
      ),
      transactionDate: '0',
      status: status,
    )..pendingCompletePurchase = true;

void main() {
  late FakeStore store;
  late PurchaseService service;

  setUp(() {
    store = FakeStore();
    service = PurchaseService(store: store, supported: true);
  });

  tearDown(() => service.dispose());

  /// Starts the service with a verifier that records what it was asked to
  /// credit and answers with [credits] (null meaning the server refused).
  Future<List<String>> startWith(int? credits) async {
    final seen = <String>[];
    await service.start(
      verify: ({required productId, required purchaseToken, required isSubscription}) async {
        seen.add('$productId:$purchaseToken');
        return credits;
      },
      productIds: {'credits_12'},
    );
    return seen;
  }

  test('credits a purchase and then completes it with the store', () async {
    final seen = await startWith(12);
    final events = <PurchaseEvent>[];
    service.events.listen(events.add);

    store.emit([receipt()]);
    await pumpEventQueue();

    expect(seen, ['credits_12:play-token-1'],
        reason: 'the receipt goes to the server for verification');
    expect(events.single.outcome, PurchaseOutcome.credited);
    expect(events.single.credited, 12);
    expect(store.completed, hasLength(1),
        reason: 'completing consumes the purchase so it can be bought again');
  });

  test('does not complete a purchase the server would not credit', () async {
    await startWith(null);
    final events = <PurchaseEvent>[];
    service.events.listen(events.add);

    store.emit([receipt()]);
    await pumpEventQueue();

    expect(events.single.outcome, PurchaseOutcome.failed);
    expect(
      store.completed,
      isEmpty,
      reason: 'an uncompleted purchase is replayed by the store, so someone '
          'who paid is credited on the next launch instead of losing it',
    );
  });

  test('reports a receipt the server had already credited', () async {
    await startWith(0);
    final events = <PurchaseEvent>[];
    service.events.listen(events.add);

    store.emit([receipt(status: PurchaseStatus.restored)]);
    await pumpEventQueue();

    expect(events.single.outcome, PurchaseOutcome.credited);
    expect(events.single.credited, 0, reason: 'restoring grants nothing new');
    expect(store.completed, hasLength(1));
  });

  test('a cancelled purchase is not an error and asks for no credit', () async {
    final seen = await startWith(12);
    final events = <PurchaseEvent>[];
    service.events.listen(events.add);

    store.emit([receipt(status: PurchaseStatus.canceled)]);
    await pumpEventQueue();

    expect(events.single.outcome, PurchaseOutcome.cancelled);
    expect(seen, isEmpty, reason: 'nothing was bought, so nothing to verify');
  });

  test('surfaces the store price rather than our own', () async {
    await startWith(12);
    expect(service.detailsFor('credits_12')?.price, '₺34,99');
  });

  test('buying an unknown pack fails instead of throwing', () async {
    await startWith(12);
    final events = <PurchaseEvent>[];
    service.events.listen(events.add);

    await service.buy('credits_999');
    await pumpEventQueue();

    expect(events.single.outcome, PurchaseOutcome.failed);
    expect(store.buyCalls, 0);
  });

  test('restores past purchases on startup', () async {
    await startWith(12);
    expect(store.restoreCalls, 1,
        reason: 'a purchase interrupted by a crash is credited on relaunch');
  });

  test('stays inert where there is no store', () async {
    final unsupported = PurchaseService(store: store, supported: false);
    addTearDown(unsupported.dispose);

    await unsupported.start(
      verify: ({required productId, required purchaseToken, required isSubscription}) async => 12,
      productIds: {'credits_12'},
    );

    expect(store.restoreCalls, 0);
    expect(unsupported.supported, isFalse);
  });
}
