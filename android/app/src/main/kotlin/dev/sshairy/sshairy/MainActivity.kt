package dev.sshairy.sshairy

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
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
    private var pendingStorageResult: MethodChannel.Result? = null
    private val updater by lazy { AndroidUpdater(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "updateAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                "installUpdate" -> {
                    val path = call.argument<String>("path")
                    val version = call.argument<String>("version")
                    if (path == null || version == null) result.success("failed") else updater.install(path, version, result)
                }
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
                "sharedStoragePath" -> {
                    val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        Environment.isExternalStorageManager()
                    } else {
                        ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) ==
                            PackageManager.PERMISSION_GRANTED &&
                            ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                            PackageManager.PERMISSION_GRANTED
                    }
                    result.success(if (granted) Environment.getExternalStorageDirectory().absolutePath else null)
                }
                "requestAllFilesAccess" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        if (Environment.isExternalStorageManager()) {
                            result.success(true)
                        } else {
                            if (pendingStorageResult != null) {
                                result.success(false)
                                return@setMethodCallHandler
                            }
                            pendingStorageResult = result
                            try {
                                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                                    data = Uri.parse("package:$packageName")
                                }
                                startActivityForResult(intent, REQ_STORAGE_SETTINGS)
                            } catch (_: android.content.ActivityNotFoundException) {
                                pendingStorageResult = null
                                result.success(false)
                            }
                        }
                    } else {
                        val hasRead = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) ==
                            PackageManager.PERMISSION_GRANTED
                        val hasWrite = ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                            PackageManager.PERMISSION_GRANTED
                        if (hasRead && hasWrite) {
                            result.success(true)
                        } else {
                            pendingStorageResult?.success(false)
                            pendingStorageResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(
                                    Manifest.permission.READ_EXTERNAL_STORAGE,
                                    Manifest.permission.WRITE_EXTERNAL_STORAGE,
                                ),
                                REQ_STORAGE,
                            )
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
        } else if (requestCode == REQ_STORAGE) {
            val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            pendingStorageResult?.success(granted)
            pendingStorageResult = null
        }
    }

    @Deprecated("Used to receive the result of the Android storage settings screen")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_STORAGE_SETTINGS && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            pendingStorageResult?.success(Environment.isExternalStorageManager())
            pendingStorageResult = null
        }
    }

    companion object {
        private const val REQ_STORAGE_SETTINGS = 47831
        private const val CHANNEL = "dev.sshairy.sshairy/mobile_platform"
        private const val REQ_NOTIFICATIONS = 47829
        private const val REQ_STORAGE = 47830
    }
}
