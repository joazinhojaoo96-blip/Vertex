// language: Objective-C, file: dylib/vertexhook.m, StoreKit purchase hook
// loaded into target app via vts_inject_dylib; turns SKPaymentQueue into an
// instant-success queue: canMakePayments always YES, addPayment resolves to a
// purchased transaction delivered to every observer, restore finishes clean.
#import <Foundation/Foundation.h>
#import <StoreKit/StoreKit.h>
#import <objc/runtime.h>

static NSHashTable *g_observers = nil;

static NSHashTable<id<SKPaymentTransactionObserver>> *vt_observers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_observers = [NSHashTable weakObjectsHashTable];
    });
    return g_observers;
}

#pragma mark - synthetic transactions

@interface VTFakePayment : SKPayment
@property (nonatomic, copy) NSString *vt_productId;
@end

@implementation VTFakePayment
- (NSString *)productIdentifier { return self.vt_productId ?: @""; }
@end

@interface VTFakeTransaction : SKPaymentTransaction
@property (nonatomic, strong) SKPayment *vt_payment;
@property (nonatomic, copy) NSString *vt_txId;
@end

@implementation VTFakeTransaction
- (SKPayment *)payment { return self.vt_payment; }
- (SKPaymentTransactionState)transactionState { return SKPaymentTransactionStatePurchased; }
- (NSString *)transactionIdentifier {
    return self.vt_txId ?: [[NSUUID UUID] UUIDString];
}
- (NSDate *)transactionDate { return [NSDate date]; }
- (NSError *)error { return nil; }
@end

static void vt_deliver(SKPaymentTransaction *tx) {
    NSArray *obs;
    @synchronized (vt_observers()) {
        obs = [vt_observers() allObjects];
    }
    if (obs.count == 0) return;

    void (^fire)(void) = ^{
        for (id<SKPaymentTransactionObserver> o in obs) {
            if ([o respondsToSelector:@selector(paymentQueue:updatedTransactions:)])
                [o paymentQueue:[SKPaymentQueue defaultQueue] updatedTransactions:@[tx]];
        }
    };
    if ([NSThread isMainThread]) fire();
    else dispatch_async(dispatch_get_main_queue(), fire);
}

static void vt_deliverFinish(void) {
    NSArray *obs;
    @synchronized (vt_observers()) {
        obs = [vt_observers() allObjects];
    }
    if (obs.count == 0) return;

    void (^fire)(void) = ^{
        for (id<SKPaymentTransactionObserver> o in obs) {
            if ([o respondsToSelector:
                    @selector(paymentQueueRestoreCompletedTransactionsFinished:)])
                [o paymentQueueRestoreCompletedTransactionsFinished:
                    [SKPaymentQueue defaultQueue]];
        }
    };
    if ([NSThread isMainThread]) fire();
    else dispatch_async(dispatch_get_main_queue(), fire);
}

#pragma mark - swizzles

static void vt_swizzle(Class cls, SEL orig, SEL repl) {
    Method m1 = class_getInstanceMethod(cls, orig);
    Method m2 = class_getInstanceMethod(cls, repl);
    if (!m1 || !m2) return;
    method_exchangeImplementations(m1, m2);
}

static void vt_swizzle_class(Class cls, SEL orig, SEL repl) {
    Method m1 = class_getClassMethod(cls, orig);
    Method m2 = class_getClassMethod(cls, repl);
    if (!m1 || !m2) return;
    method_exchangeImplementations(m1, m2);
}

@interface SKPaymentQueue (VertexHook)
- (void)vt_addPayment:(SKPayment *)payment;
- (void)vt_addObserver:(id<SKPaymentTransactionObserver>)observer;
- (void)vt_removeObserver:(id<SKPaymentTransactionObserver>)observer;
- (void)vt_finish:(SKPaymentTransaction *)transaction;
- (void)vt_restore;
@end

@implementation SKPaymentQueue (VertexHook)

// observers tracked weakly: the queue's own list has no public getter,
// and weak refs keep dead controllers from receiving stale updates
- (void)vt_addObserver:(id<SKPaymentTransactionObserver>)observer {
    @synchronized (vt_observers()) {
        if (observer) [vt_observers() addObject:observer];
    }
    [self vt_addObserver:observer];
}

- (void)vt_removeObserver:(id<SKPaymentTransactionObserver>)observer {
    @synchronized (vt_observers()) {
        if (observer) [vt_observers() removeObject:observer];
    }
    [self vt_removeObserver:observer];
}

- (void)vt_addPayment:(SKPayment *)payment {
    if (!payment) return;

    VTFakeTransaction *tx = [VTFakeTransaction new];
    VTFakePayment *paid = [VTFakePayment new];
    paid.vt_productId = ((VTFakePayment *)payment).productIdentifier ?: @"";
    tx.vt_payment = paid;
    tx.vt_txId = [NSString stringWithFormat:@"vertex-%@-%.0f",
                  paid.vt_productId, [NSDate date].timeIntervalSince1970];
    vt_deliver(tx);
}

- (void)vt_finish:(SKPaymentTransaction *)transaction {
    (void)transaction;   // synthetic tx never entered the real queue
}

- (void)vt_restore {
    vt_deliverFinish();
}

@end

@interface SKPaymentQueue (VertexClassHook)
+ (BOOL)vt_canPay;
@end

@implementation SKPaymentQueue (VertexClassHook)
+ (BOOL)vt_canPay { return YES; }
@end

#pragma mark - entry

__attribute__((constructor))
static void vertexhook_init(void) {
    @autoreleasepool {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            vt_swizzle([SKPaymentQueue class],
                       @selector(addPayment:),
                       @selector(vt_addPayment:));
            vt_swizzle([SKPaymentQueue class],
                       @selector(addTransactionObserver:),
                       @selector(vt_addObserver:));
            vt_swizzle([SKPaymentQueue class],
                       @selector(removeTransactionObserver:),
                       @selector(vt_removeObserver:));
            vt_swizzle([SKPaymentQueue class],
                       @selector(finishTransaction:),
                       @selector(vt_finish:));
            vt_swizzle([SKPaymentQueue class],
                       @selector(restoreCompletedTransactions),
                       @selector(vt_restore));
            vt_swizzle_class([SKPaymentQueue class],
                             @selector(canMakePayments),
                             @selector(vt_canPay));
        });
    }
}
