package dev.sshairy.sshairy

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import io.flutter.plugin.common.MethodChannel
import java.io.File

internal class AndroidUpdater(private val activity: Activity) {
    fun install(path: String, version: String, result: MethodChannel.Result) {
        Thread {
            val apk = runCatching { validatedApk(path, version) }.getOrNull()
            activity.runOnUiThread {
                result.success(if (apk == null || activity.isFinishing || activity.isDestroyed) "failed" else open(apk))
            }
        }.start()
    }

    @Suppress("DEPRECATION")
    private fun validatedApk(path: String, version: String): File? {
        val apk = File(path).canonicalFile
        val updates = File(activity.cacheDir, "updates").canonicalFile
        if (apk.parentFile != updates || apk.extension != "apk" || !apk.isFile) return null

        val manager = activity.packageManager
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        val installed = manager.getPackageInfo(activity.packageName, flags)
        val incoming = manager.getPackageArchiveInfo(apk.path, flags) ?: return null
        if (incoming.packageName != installed.packageName || incoming.versionName != version ||
            PackageInfoCompat.getLongVersionCode(incoming) <= PackageInfoCompat.getLongVersionCode(installed)
        ) return null
        val installedSigners = signers(installed)
        return apk.takeIf { installedSigners.isNotEmpty() && signers(incoming) == installedSigners }
    }

    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        info.signingInfo?.apkContentsSigners?.toSet().orEmpty()
    } else {
        info.signatures?.toSet().orEmpty()
    }

    private fun open(apk: File): String = try {
        if (!activity.packageManager.canRequestPackageInstalls()) {
            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
            "permission"
        } else {
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", apk)
            activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            })
            "opened"
        }
    } catch (_: RuntimeException) {
        "failed"
    }
}
