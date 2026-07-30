package com.liveness.trueface_liveness

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry

/**
 * Entry point of the liveness detection plugin.
 *
 * Registers the [LivenessViewFactory] for the `com.trueface/trueface_liveness_view`
 * platform view and, via [ActivityAware], exposes the current [Activity] so
 * views can request the runtime camera permission.
 */
class TrueFaceLivenessPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {

    companion object {
        const val VIEW_TYPE = "com.trueface/trueface_liveness_view"
        private const val CAMERA_PERMISSION_REQUEST_CODE = 4907
    }

    private lateinit var channel: MethodChannel
    private var activityBinding: ActivityPluginBinding? = null
    private val pendingPermissionCallbacks = mutableListOf<(Boolean) -> Unit>()

    /** The activity the engine is currently attached to, if any. */
    val activity: Activity?
        get() = activityBinding?.activity

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "trueface_liveness")
        channel.setMethodCallHandler(this)
        flutterPluginBinding.platformViewRegistry.registerViewFactory(
            VIEW_TYPE,
            LivenessViewFactory(flutterPluginBinding.binaryMessenger, this),
        )
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        if (call.method == "getPlatformVersion") {
            result.success("Android ${android.os.Build.VERSION.RELEASE}")
        } else {
            result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    // ---------------------------------------------------------------- Activity

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        // Without an activity a permission dialog can never resolve.
        val callbacks = pendingPermissionCallbacks.toList()
        pendingPermissionCallbacks.clear()
        callbacks.forEach { it(false) }
    }

    // -------------------------------------------------------------- Permission

    /**
     * Requests the runtime CAMERA permission from the attached activity and
     * reports the outcome to [onResult] (on the main thread). Reports `false`
     * immediately when no activity is attached.
     */
    fun requestCameraPermission(onResult: (Boolean) -> Unit) {
        val activity = this.activity
        if (activity == null) {
            onResult(false)
            return
        }
        if (ActivityCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            onResult(true)
            return
        }
        pendingPermissionCallbacks += onResult
        if (pendingPermissionCallbacks.size == 1) {
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.CAMERA),
                CAMERA_PERMISSION_REQUEST_CODE,
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != CAMERA_PERMISSION_REQUEST_CODE) return false
        val granted =
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        val callbacks = pendingPermissionCallbacks.toList()
        pendingPermissionCallbacks.clear()
        callbacks.forEach { it(granted) }
        return true
    }
}
