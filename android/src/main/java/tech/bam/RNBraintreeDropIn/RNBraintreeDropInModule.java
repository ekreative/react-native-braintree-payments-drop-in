package tech.bam.RNBraintreeDropIn;

import android.app.Activity;
import android.content.Intent;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AppCompatActivity;

import com.braintreepayments.api.BraintreeFragment;
import com.braintreepayments.api.DataCollector;
import com.braintreepayments.api.exceptions.InvalidArgumentException;
import com.braintreepayments.api.interfaces.BraintreeResponseListener;
import com.braintreepayments.api.models.GooglePaymentRequest;
import com.braintreepayments.api.models.ThreeDSecureAdditionalInformation;
import com.braintreepayments.api.models.ThreeDSecurePostalAddress;
import com.braintreepayments.api.models.ThreeDSecureRequest;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.bridge.BaseActivityEventListener;
import com.braintreepayments.api.dropin.DropInActivity;
import com.braintreepayments.api.dropin.DropInRequest;
import com.braintreepayments.api.dropin.DropInResult;
import com.braintreepayments.api.models.PaymentMethodNonce;
import com.braintreepayments.api.models.CardNonce;
import com.braintreepayments.api.models.ThreeDSecureInfo;
import com.google.android.gms.wallet.TransactionInfo;
import com.google.android.gms.wallet.WalletConstants;
import com.facebook.react.bridge.Promise;


public class RNBraintreeDropInModule extends ReactContextBaseJavaModule {

    private Promise mPromise;
    private String mClientToken;
    private static final int DROP_IN_REQUEST = 0x444;

    RNBraintreeDropInModule(ReactApplicationContext reactContext) {
        super(reactContext);
        reactContext.addActivityEventListener(new BaseActivityEventListener() {
            @Override
            public void onActivityResult(Activity activity, int requestCode, int resultCode, Intent data) {
                super.onActivityResult(activity, requestCode, resultCode, data);

                if (requestCode != DROP_IN_REQUEST || mPromise == null) {
                    return;
                }

                if (resultCode == Activity.RESULT_OK) {
                    DropInResult result = data.getParcelableExtra(DropInResult.EXTRA_DROP_IN_RESULT);
                    PaymentMethodNonce paymentMethodNonce = result.getPaymentMethodNonce();

                    if (paymentMethodNonce instanceof CardNonce) {
                        CardNonce cardNonce = (CardNonce) paymentMethodNonce;
                        ThreeDSecureInfo threeDSecureInfo = cardNonce.getThreeDSecureInfo();
                        if (!threeDSecureInfo.isLiabilityShiftPossible()) {
                            mPromise.reject("3DSECURE_NOT_ABLE_TO_SHIFT_LIABILITY", "3D Secure liability cannot be shifted");
                            return;
                        } else if (!threeDSecureInfo.isLiabilityShifted()) {
                            mPromise.reject("3DSECURE_LIABILITY_NOT_SHIFTED", "3D Secure liability was not shifted");
                            return;
                        }
                    }
                    resolvePayment(paymentMethodNonce, activity);
                } else if (resultCode == Activity.RESULT_CANCELED) {
                    mPromise.reject("USER_CANCELLATION", "The user cancelled");
                } else {
                    Exception exception = (Exception) data.getSerializableExtra(DropInActivity.EXTRA_ERROR);
                    mPromise.reject(exception.getMessage(), exception.getMessage());
                }

                mPromise = null;
            }
        });
    }

    @ReactMethod
    public void show(final ReadableMap options, final Promise promise) {
        if (!options.hasKey("clientToken")) {
            promise.reject("NO_CLIENT_TOKEN", "You must provide a client token");
            return;
        } else {
            mClientToken = options.getString("clientToken");
        }

        Activity currentActivity = getCurrentActivity();
        if (currentActivity == null) {
            promise.reject("NO_ACTIVITY", "There is no current activity");
            return;
        }

        boolean disabledVaultManager = !options.hasKey("disabledVaultManager")
                || (options.hasKey("disabledVaultManager")
                && !options.getBoolean("disabledVaultManager"));

        final ReadableMap threeDSecureOptions = options.getMap("threeDSecure");
        if (threeDSecureOptions == null) {
            promise.reject("THREEDSECURE_IS_NULL", "3D Secure options were not provided");
            return;
        }

        final ThreeDSecurePostalAddress address;
        try {
            address = new ThreeDSecurePostalAddress()
                    .givenName(threeDSecureOptions.getString("firstName"))
                    .surname(threeDSecureOptions.getString("lastName"))
                    .phoneNumber(threeDSecureOptions.getString("phoneNumber"))
                    .streetAddress(threeDSecureOptions.getString("streetAddress"))
                    .extendedAddress(threeDSecureOptions.getString("streetAddress2"))
                    .locality(threeDSecureOptions.getString("city"))
                    .region(threeDSecureOptions.getString("region"))
                    .postalCode(threeDSecureOptions.getString("postalCode"))
                    .countryCodeAlpha2(threeDSecureOptions.getString("countryCode"));
        } catch (Exception error) {
            promise.reject("ADDRESS_ERROR", "Failed to prepare address");
            return;
        }

        ThreeDSecureAdditionalInformation additionalInformation = new ThreeDSecureAdditionalInformation()
                .shippingAddress(address);

        ThreeDSecureRequest threeDSecureRequest;
        try {
            threeDSecureRequest = new ThreeDSecureRequest()
                    .amount(threeDSecureOptions.getString("amount"))
                    .email(threeDSecureOptions.getString("email"))
                    .billingAddress(address)
                    .versionRequested(ThreeDSecureRequest.VERSION_2)
                    .additionalInformation(additionalInformation);
        } catch (Exception error) {
            promise.reject("THREEDSECURE_FAILED", error.getMessage());
            return;
        }

        DropInRequest dropInRequest = new DropInRequest()
                .requestThreeDSecureVerification(true)
                .threeDSecureRequest(threeDSecureRequest)
                .vaultManager(disabledVaultManager)
                .clientToken(options.getString("clientToken"));

        try {
            String amount = threeDSecureOptions.getString("amount");
            String currencyCode = options.getString("currencyCode");
            String merchantId = options.getString("GPayMerchantId");
            String env = "test".equals(merchantId) ? "TEST" : "PRODUCTION";
            if (merchantId != null && amount != null && currencyCode != null) {
                GooglePaymentRequest googlePaymentRequest = new GooglePaymentRequest()
                        .transactionInfo(TransactionInfo.newBuilder()
                                .setTotalPrice(amount)
                                .setTotalPriceStatus(WalletConstants.TOTAL_PRICE_STATUS_FINAL)
                                .setCurrencyCode(currencyCode)
                                .build())
                        .billingAddressRequired(true)
                        .googleMerchantId(merchantId)
                        .environment(env);
                dropInRequest.googlePaymentRequest(googlePaymentRequest);
            }
        } catch (Exception ignored) {
        }

        mPromise = promise;
        currentActivity.startActivityForResult(dropInRequest.getIntent(currentActivity), DROP_IN_REQUEST);
    }


    private void resolvePayment(PaymentMethodNonce paymentMethodNonce, Activity currentActivity) {
        try {
            WritableMap jsResult = Arguments.createMap();
            jsResult.putString("nonce", paymentMethodNonce.getNonce());
            jsResult.putString("type", paymentMethodNonce.getTypeLabel());
            jsResult.putString("description", paymentMethodNonce.getDescription());
            jsResult.putBoolean("isDefault", paymentMethodNonce.isDefault());
            extractDeviceData(currentActivity, jsResult);
        } catch (NullPointerException ignore) {
            mPromise.reject("PAYMENT_NONCE_RESOLVE_FAILED", "Failed to resolve payment nonce");
        }
    }

    private void extractDeviceData(Activity currentActivity, final WritableMap jsResult) {
        if (currentActivity instanceof AppCompatActivity) {
            try {
                BraintreeFragment braintreeFragment = BraintreeFragment.newInstance(
                        (AppCompatActivity) currentActivity,
                        mClientToken);
                DataCollector.collectDeviceData(braintreeFragment, new BraintreeResponseListener<String>() {
                    @Override
                    public void onResponse(String deviceData) {
                        jsResult.putString("deviceData", deviceData);
                        mPromise.resolve(jsResult);
                    }
                });
            } catch (InvalidArgumentException e) {
                e.printStackTrace();
                mPromise.resolve(jsResult);
            }
        } else {
            Log.e("DropInModule", "Failed to extract device data, activity is not AppCompat");
            mPromise.resolve(jsResult);
        }
    }

    @NonNull
    @Override
    public String getName() {
        return "RNBraintreeDropIn";
    }
}
