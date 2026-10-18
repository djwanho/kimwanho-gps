package com.kimwanho.gpswalknavigator

import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Log
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Android system PiP (not a SYSTEM_ALERT_WINDOW overlay).
 * Only enabled during the user's active navigation session.
 */
class MainActivity : FlutterActivity() {
    private val pipChannelName = "com.kimwanho.gpswalknavigator/pip"
    private var pipChannel: MethodChannel? = null
    private var navigationActive = false

    private fun canUsePip(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun updatePipParams() {
        if (!canUsePip()) return
        try {
            val builder = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(4, 3))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setAutoEnterEnabled(navigationActive)
                builder.setSeamlessResizeEnabled(true)
            }
            setPictureInPictureParams(builder.build())
        } catch (e: Exception) {
            Log.w("KimWanHoPiP", "Unable to set PiP parameters", e)
        }
    }

    private fun enterPip(): Boolean {
        if (!canUsePip() || !navigationActive || isFinishing) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isInPictureInPictureMode) {
            return true
        }
        return try {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(4, 3))
                .build()
            enterPictureInPictureMode(params)
        } catch (e: Exception) {
            Log.w("KimWanHoPiP", "PiP transition refused", e)
            false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pipChannelName)
        pipChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(canUsePip())
                "isInPip" -> result.success(
                    canUsePip() && isInPictureInPictureMode
                )
                "setNavigationActive" -> {
                    navigationActive = (call.arguments as? Boolean) == true
                    updatePipParams()
                    result.success(true)
                }
                "enterPip" -> result.success(enterPip())
                else -> result.notImplemented()
            }
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 12+ uses setAutoEnterEnabled for smoother gesture transitions.
        if (canUsePip() && Build.VERSION.SDK_INT < Build.VERSION_CODES.S &&
            navigationActive) {
            enterPip()
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("pipModeChanged", isInPictureInPictureMode)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        pipChannel?.setMethodCallHandler(null)
        pipChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
