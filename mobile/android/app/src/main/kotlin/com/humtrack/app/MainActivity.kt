package com.humtrack.app

import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "humming/audio"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasHeadset" -> result.success(headsetRoute() != "none")
                "headsetRoute" -> result.success(headsetRoute())
                else -> result.notImplemented()
            }
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
