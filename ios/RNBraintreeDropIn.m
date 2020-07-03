#import "RNBraintreeDropIn.h"
@import PassKit;
#import "BraintreeApplePay.h"
#import "BTThreeDSecureRequest.h"
#import "BTUIKAppearance.h"

@interface RNBraintreeDropIn() <PKPaymentAuthorizationViewControllerDelegate>

@property (nonatomic, strong) BTAPIClient *apiClient;
@property (nonatomic, strong) RCTPromiseResolveBlock resolve;
@property (nonatomic, strong) RCTPromiseRejectBlock reject;
@property (nonatomic, assign) BOOL isApplePaymentAuthorized;

@end

@implementation RNBraintreeDropIn

- (dispatch_queue_t)methodQueue
{
    return dispatch_get_main_queue();
}
RCT_EXPORT_MODULE()

RCT_REMAP_METHOD(show,
                 showWithOptions:(NSDictionary*)options resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
{
    NSString* clientToken = options[@"clientToken"];
    if (!clientToken) {
        reject(@"NO_CLIENT_TOKEN", @"You must provide a client token", nil);
        return;
    }

    BTUIKAppearance.sharedInstance.postalCodeFormFieldKeyboardType = UIKeyboardTypeNamePhonePad;

    BTDropInRequest *request = [[BTDropInRequest alloc] init];
    request.threeDSecureVerification = YES;

    if (!options[@"disabledVaultManager"]) {
        request.vaultManager = YES;
    }

    NSDictionary* threeDSecureOptions = options[@"threeDSecure"];

    BTThreeDSecureRequest *threeDSecureRequest = [[BTThreeDSecureRequest alloc] init];
    threeDSecureRequest.amount = [NSDecimalNumber decimalNumberWithString:threeDSecureOptions[@"amount"]];
    threeDSecureRequest.email = threeDSecureOptions[@"email"];
    threeDSecureRequest.versionRequested = BTThreeDSecureVersion2;
    
    BTThreeDSecurePostalAddress *address = [BTThreeDSecurePostalAddress new];
    address.givenName = threeDSecureOptions[@"firstName"];
    address.surname = threeDSecureOptions[@"lastName"];
    address.phoneNumber = threeDSecureOptions[@"phoneNumber"];
    address.streetAddress = threeDSecureOptions[@"streetAddress"];
    address.extendedAddress = threeDSecureOptions[@"streetAddress2"];
    address.locality = threeDSecureOptions[@"city"];
    address.region = threeDSecureOptions[@"region"];
    address.postalCode = threeDSecureOptions[@"postalCode"];
    address.countryCodeAlpha2 = threeDSecureOptions[@"countryCode"];
    threeDSecureRequest.billingAddress = address;

    BTThreeDSecureAdditionalInformation *additionalInformation = [BTThreeDSecureAdditionalInformation new];
    additionalInformation.shippingAddress = address;
    threeDSecureRequest.additionalInformation = additionalInformation;

    request.threeDSecureRequest = threeDSecureRequest;

    BTDropInController *dropIn = [[BTDropInController alloc] initWithAuthorization:clientToken request:request handler:^(BTDropInController * _Nonnull controller, BTDropInResult * _Nullable result, NSError * _Nullable error) {
            [self.reactRoot dismissViewControllerAnimated:YES completion:nil];

            if (error != nil) {
                reject(error.localizedDescription, error.localizedDescription, error);
            } else if (result.cancelled) {
                reject(@"USER_CANCELLATION", @"The user cancelled", nil);
            } else {
                if (threeDSecureOptions && [result.paymentMethod isKindOfClass:[BTCardNonce class]]) {
                    BTCardNonce *cardNonce = (BTCardNonce *)result.paymentMethod;
                    if (!cardNonce.threeDSecureInfo.liabilityShiftPossible && cardNonce.threeDSecureInfo.wasVerified) {
                        reject(@"3DSECURE_NOT_ABLE_TO_SHIFT_LIABILITY", @"3D Secure liability cannot be shifted", nil);
                    } else if (!cardNonce.threeDSecureInfo.liabilityShifted && cardNonce.threeDSecureInfo.wasVerified) {
                        reject(@"3DSECURE_LIABILITY_NOT_SHIFTED", @"3D Secure liability was not shifted", nil);
                    } else {
                        [[self class] resolvePayment :result resolver:resolve];
                    }
                } else if (result.paymentOptionType == BTUIKPaymentOptionTypeApplePay) {
                    if (!options[@"companyName"]) {
                        reject(@"NO_COMPANY_NAME", @"You must provide a company name", nil);
                        return;
                    }
                    if (!threeDSecureOptions[@"amount"]) {
                        reject(@"NO_TOTAL_PRICE", @"You must provide a total price", nil);
                        return;
                    }
                    self.apiClient = [[BTAPIClient alloc] initWithAuthorization:clientToken];
                    self.resolve = resolve;
                    self.reject = reject;
                    [self setupPaymentRequest:^(PKPaymentRequest *paymentRequest, NSError *error) {
                        [self setIsApplePaymentAuthorized: NO];
                        PKPaymentAuthorizationViewController *vc = [[PKPaymentAuthorizationViewController alloc] initWithPaymentRequest:paymentRequest];
                        vc.delegate = self;
                        [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:vc animated:YES completion:NULL];
                    } options: options];
                } else {
                    [[self class] resolvePayment :result resolver:resolve];
                }
            }
        }];

    if (dropIn != nil) {
        [self.reactRoot presentViewController:dropIn animated:YES completion:nil];
    } else {
        reject(@"INVALID_CLIENT_TOKEN", @"The client token seems invalid", nil);
    }
}

+ (void)resolvePayment:(BTDropInResult* _Nullable)result resolver:(RCTPromiseResolveBlock _Nonnull)resolve {
    NSMutableDictionary* jsResult = [NSMutableDictionary new];
    [jsResult setObject:result.paymentMethod.nonce forKey:@"nonce"];
    [jsResult setObject:result.paymentMethod.type forKey:@"type"];
    [jsResult setObject:result.paymentDescription forKey:@"description"];
    [jsResult setObject:[NSNumber numberWithBool:result.paymentMethod.isDefault] forKey:@"isDefault"];
    resolve(jsResult);
}

- (void)setupPaymentRequest:(void (^)(PKPaymentRequest * _Nullable, NSError * _Nullable))completion options:(NSDictionary*)options {
    BTApplePayClient *applePayClient = [[BTApplePayClient alloc] initWithAPIClient:self.apiClient];
    // You can use the following helper method to create a PKPaymentRequest which will set the `countryCode`,
    // `currencyCode`, `merchantIdentifier`, and `supportedNetworks` properties.
    // You can also create the PKPaymentRequest manually. Be aware that you'll need to keep these in
    // sync with the gateway settings if you go this route.
    [applePayClient paymentRequest:^(PKPaymentRequest * _Nullable paymentRequest, NSError * _Nullable error) {
        if (error) {
            completion(nil, error);
            return;
        }

        // We recommend collecting billing address information, at minimum
        // billing postal code, and passing that billing postal code with all
        // Apple Pay transactions as a best practice.
        if (@available(iOS 11.0, *)) {
            paymentRequest.requiredBillingContactFields = [NSSet setWithObject:PKContactFieldPostalAddress];
        }

        NSDictionary* threeDSecureOptions = options[@"threeDSecure"];

        // Set other PKPaymentRequest properties here
        paymentRequest.merchantCapabilities = PKMerchantCapability3DS;
        paymentRequest.paymentSummaryItems =
        @[
            //[PKPaymentSummaryItem summaryItemWithLabel:options[@"itemName"] amount:[NSDecimalNumber decimalNumberWithString:threeDSecureOptions[@"amount"]]],
            // Add add'l payment summary items...
            [PKPaymentSummaryItem summaryItemWithLabel:options[@"companyName"] amount:[NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%@", threeDSecureOptions[@"amount"]]]]
        ];

        // Save the PKPaymentRequest or start the payment flow
        completion(paymentRequest, nil);
    }];
}

- (UIViewController*)reactRoot {
    UIViewController *root  = [UIApplication sharedApplication].keyWindow.rootViewController;
    UIViewController *maybeModal = root.presentedViewController;

    UIViewController *modalRoot = root;

    if (maybeModal != nil) {
        modalRoot = maybeModal;
    }

    return modalRoot;
}

- (void)paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller
                       didAuthorizePayment:(PKPayment *)payment
                                completion:(void (^)(PKPaymentAuthorizationStatus))completion {

    [self setIsApplePaymentAuthorized: YES];
    // Example: Tokenize the Apple Pay payment
    BTApplePayClient *applePayClient = [[BTApplePayClient alloc]
                                        initWithAPIClient:self.apiClient];
    [applePayClient tokenizeApplePayPayment:payment
                                 completion:^(BTApplePayCardNonce *tokenizedApplePayPayment,
                                              NSError *error) {
        if (tokenizedApplePayPayment) {
            // On success, send nonce to your server for processing.
            NSLog(@"nonce = %@", tokenizedApplePayPayment.nonce);
            NSLog(@"description = %@", tokenizedApplePayPayment.localizedDescription);
            NSLog(@"type = %@", tokenizedApplePayPayment.type);

            // If requested, address information is accessible in `payment` and may
            // also be sent to your server.
            NSLog(@"billingPostalCode = %@", payment.billingContact.postalAddress.postalCode);

            // Then indicate success or failure via the completion callback, e.g.
            NSMutableDictionary* jsResult = [NSMutableDictionary new];
            [jsResult setObject:tokenizedApplePayPayment.nonce forKey:@"nonce"];
            [jsResult setObject:tokenizedApplePayPayment.localizedDescription forKey:@"type"];
            [jsResult setObject:tokenizedApplePayPayment.type forKey:@"description"];
            self.resolve(jsResult);
            completion(PKPaymentAuthorizationStatusSuccess);
        } else {
            // Tokenization failed. Check `error` for the cause of the failure.
            self.reject(error.localizedDescription, error.localizedDescription, error);
            // Indicate failure via the completion callback:
            completion(PKPaymentAuthorizationStatusFailure);
        }
        self.resolve = NULL;
        self.reject = NULL;
    }];
}

- (void)paymentAuthorizationViewControllerDidFinish:(nonnull PKPaymentAuthorizationViewController *)controller {
    [self.reactRoot dismissViewControllerAnimated:YES completion:NULL];
    if (self.reject) {
        if (self.isApplePaymentAuthorized == NO) {
            self.reject(@"USER_CANCELLATION", @"The user cancelled", nil);
        } else {
            self.reject(@"APPLE_PAY_FAILED", @"Apple Pay failed", nil);
        }
    }
    
    self.resolve = NULL;
    self.reject = NULL;
    self.isApplePaymentAuthorized = NULL;
}

@end
