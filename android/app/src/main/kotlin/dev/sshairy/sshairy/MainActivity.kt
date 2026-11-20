package dev.sshairy.sshairy

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var pendingNotifResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setKeepScreenOn" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    runOnUiThread {
                        if (on) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                }
                "startKeepAlive" -> {
                    val title = call.argument<String>("title") ?: "Sshairy"
                    val subtitle = call.argument<String>("subtitle") ?: ""
                    try {
                        val intent = Intent(this, KeepAliveService::class.java).apply {
                            action = KeepAliveService.ACTION_START
                            putExtra(KeepAliveService.EXTRA_TITLE, title)
                            putExtra(KeepAliveService.EXTRA_SUBTITLE, subtitle)
                        }
                        ContextCompat.startForegroundService(this, intent)
                        result.success(true)
                    } catch (_: Throwable) {
                        result.success(false)
                    }
                }
                "stopKeepAlive" -> {
                    try {
                        val intent = Intent(this, KeepAliveService::class.java).apply {
                            action = KeepAliveService.ACTION_STOP
                        }
                        stopService(intent)
                    } catch (_: Throwable) {
                    }
                    result.success(null)
                }
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                        result.success(true)
                    } else if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                        == PackageManager.PERMISSION_GRANTED
                    ) {
                        result.success(true)
                    } else {
                        pendingNotifResult?.success(false)
                        pendingNotifResult = result
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            REQ_NOTIFICATIONS,
                        )
                    }
                }
                "canAuthenticateBiometric" -> {
                    val manager = BiometricManager.from(this)
                    val status = manager.canAuthenticate(
                        BiometricManager.Authenticators.BIOMETRIC_STRONG or
                            BiometricManager.Authenticators.BIOMETRIC_WEAK or
                            BiometricManager.Authenticators.DEVICE_CREDENTIAL,
                    )
                    result.success(status == BiometricManager.BIOMETRIC_SUCCESS)
                }
                "authenticateBiometric" -> {
                    val title = call.argument<String>("title") ?: "Sshairy"
                    val subtitle = call.argument<String>("subtitle") ?: ""
                    runOnUiThread {
                        try {
                            val executor = ContextCompat.getMainExecutor(this)
                            val prompt = BiometricPrompt(
                                this,
                                executor,
                                object : BiometricPrompt.AuthenticationCallback() {
                                    override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) {
                                        result.success(true)
                                    }

                                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                                        result.success(false)
                                    }
                                },
                            )
                            val info = BiometricPrompt.PromptInfo.Builder()
                                .setTitle(title)
                                .setSubtitle(subtitle)
                                .setAllowedAuthenticators(
                                    BiometricManager.Authenticators.BIOMETRIC_STRONG or
                                        BiometricManager.Authenticators.BIOMETRIC_WEAK or
                                        BiometricManager.Authenticators.DEVICE_CREDENTIAL,
                                )
                                .build()
                            prompt.authenticate(info)
                        } catch (_: Throwable) {
                            result.success(false)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIFICATIONS) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingNotifResult?.success(granted)
            pendingNotifResult = null
        }
    }

    companion object {
        private const val CHANNEL = "dev.sshairy.sshairy/mobile_platform"
        private const val REQ_NOTIFICATIONS = 47829
    }
}
