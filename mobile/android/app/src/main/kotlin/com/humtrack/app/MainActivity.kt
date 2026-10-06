package com.humtrack.app

import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "humming/audio"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "humtrack/exports").setMethodCallHandler { call, result ->
            if (call.method != "saveExport") {
                result.notImplemented()
            } else if (pendingExport != null) {
                result.error("busy", "A save dialog is already open", null)
            } else {
                try {
                    val source = java.io.File(call.argument<String>("path") ?: "").canonicalFile
                    val folder = java.io.File(io.flutter.util.PathUtils.getDataDirectory(this), "looptap/exports").canonicalFile
                    require(source.parentFile == folder && source.isFile)
                    require(source.extension.lowercase() in setOf("wav", "mid"))
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = if (source.extension.lowercase() == "mid") "audio/midi" else "audio/wav"
                        putExtra(Intent.EXTRA_TITLE, source.name)
                    }
                    pendingExport = result
                    pendingExportFile = source
                    startActivityForResult(intent, exportRequestCode)
                } catch (e: Exception) {
                    pendingExport = null
                    pendingExportFile = null
                    result.error("save_failed", "Could not open the save dialog", null)
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasHeadset" -> result.success(headsetRoute() != "none")
                "headsetRoute" -> result.success(headsetRoute())
                // Dart picks the take encoder by API level (Opus needs 29+).
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                // Mic permission denied → let the user flip it in app settings.
                "openAppSettings" -> result.success(openAppSettings())
                else -> result.notImplemented()
            }
        }
    }


    private val exportRequestCode = 8041
    private var pendingExport: MethodChannel.Result? = null
    private var pendingExportFile: java.io.File? = null

    @Deprecated("Used for the system document picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != exportRequestCode) return
        val result = pendingExport ?: return
        val source = pendingExportFile
        if (resultCode != RESULT_OK || data?.data == null || source == null) {
            pendingExport = null
            pendingExportFile = null
            result.success(false)
            return
        }
        val destination = data.data!!
        // File copying must not block note input or playback on the UI thread.
        Thread {
            try {
                val output = contentResolver.openOutputStream(destination, "w")
                    ?: throw java.io.IOException("No output stream")
                output.use { sink -> source.inputStream().use { it.copyTo(sink) } }
                runOnUiThread { pendingExport = null; pendingExportFile = null; result.success(true) }
            } catch (e: Exception) {
                runOnUiThread {
                    pendingExport = null
                    pendingExportFile = null
                    result.error("save_failed", "Could not write the selected file", null)
                }
            }
        }.start()
    }

    private fun openAppSettings(): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            intent.data = Uri.fromParts("package", packageName, null)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    // 출력 라우트 종류: "wired" | "bluetooth" | "none".
    // wired(유선/USB) → 반주 모니터링 + 저지연 실시간 오토튠 모두 가능.
    // bluetooth → 반주 모니터링은 가능하나 왕복 지연이 커서 실시간 모니터링 제외.
    // none(스피커) → 녹음 시 반주를 음소거해 마이크 피드백 방지.
    private fun headsetRoute(): String {
        val am = getSystemService(AUDIO_SERVICE) as AudioManager
        val devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val wired = setOf(
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE,
        )
        val bluetooth = mutableSetOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            bluetooth.add(AudioDeviceInfo.TYPE_BLE_HEADSET) // LE Audio, API 31+
        }
        if (devices.any { it.type in wired }) return "wired"
        if (devices.any { it.type in bluetooth }) return "bluetooth"
        return "none"
    }
}
