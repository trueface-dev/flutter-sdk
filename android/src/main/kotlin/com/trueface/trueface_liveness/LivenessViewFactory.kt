package com.trueface.trueface_liveness

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/** Builds a [LivenessView] from the creation params sent by the Dart side. */
class LivenessViewFactory(
    private val messenger: BinaryMessenger,
    private val plugin: TrueFaceLivenessPlugin,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = args as? Map<*, *> ?: emptyMap<Any?, Any?>()
        return LivenessView(context, viewId, messenger, plugin, params)
    }
}
