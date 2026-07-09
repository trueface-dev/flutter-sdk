package com.liveness.liveness_detection

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.graphics.PointF
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.util.Size
import android.view.View
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetector
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.face.FaceLandmark
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Creation params sent by the Dart `LivenessConfig.toMap()`. */
internal class LivenessConfigParams private constructor(
    val challengePool: List<String>,
    val numberOfChallenges: Int,
    val randomizeOrder: Boolean,
    val challengeTimeoutMs: Long,
    val imageQuality: Int,
    val enablePassiveAntiSpoof: Boolean,
    val spoofScoreThreshold: Double,
    val cameraLensDirection: String,
) {
    companion object {
        private val DEFAULT_POOL = listOf("blink", "smile", "turnLeft", "turnRight", "nod")

        fun fromMap(map: Map<*, *>): LivenessConfigParams {
            val pool = (map["challengePool"] as? List<*>)
                ?.filterIsInstance<String>()
                .orEmpty()
                .ifEmpty { DEFAULT_POOL }
            return LivenessConfigParams(
                challengePool = pool,
                numberOfChallenges = ((map["numberOfChallenges"] as? Number)?.toInt() ?: 3)
                    .coerceAtLeast(1),
                randomizeOrder = map["randomizeOrder"] as? Boolean ?: true,
                challengeTimeoutMs = (map["challengeTimeoutMs"] as? Number)?.toLong() ?: 12000L,
                imageQuality = ((map["imageQuality"] as? Number)?.toInt() ?: 90).coerceIn(1, 100),
                enablePassiveAntiSpoof = map["enablePassiveAntiSpoof"] as? Boolean ?: true,
                spoofScoreThreshold = ((map["spoofScoreThreshold"] as? Number)?.toDouble() ?: 0.6)
                    .coerceIn(0.0, 1.0),
                cameraLensDirection = map["cameraLensDirection"] as? String ?: "front",
            )
        }
    }
}

/**
 * The platform view: owns the CameraX pipeline (Preview + ImageAnalysis +
 * ImageCapture), the ML Kit face detector, the [ChallengeSession] state
 * machine and the [AntiSpoofDetector]. The session starts automatically as
 * soon as the runtime camera permission is granted.
 */
internal class LivenessView(
    context: Context,
    viewId: Int,
    messenger: BinaryMessenger,
    private val plugin: LivenessDetectionPlugin,
    params: Map<*, *>,
) : PlatformView, LifecycleOwner, ChallengeSession.Listener {

    companion object {
        /** Sample a texture crop for the anti-spoof detector every N frames. */
        private const val TEXTURE_SAMPLE_EVERY = 6

        /**
         * Terminal results emitted almost immediately after view creation
         * (e.g. instant permission denial) are delayed slightly so the Dart
         * side has set its MethodCallHandler by the time `onResult` arrives.
         */
        private const val EARLY_RESULT_DELAY_MS = 400L
    }

    private val appContext: Context = context.applicationContext
    private val config = LivenessConfigParams.fromMap(params)
    private val previewView = PreviewView(context)
    private val channel = MethodChannel(messenger, "com.liveness/liveness_$viewId")
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lifecycleRegistry = LifecycleRegistry(this)
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private var cameraProvider: ProcessCameraProvider? = null
    private var imageCapture: ImageCapture? = null
    private var faceDetector: FaceDetector? = null
    private var session: ChallengeSession? = null
    private val antiSpoof: AntiSpoofDetector = AntiSpoofDetector.create()

    private var disposed = false
    private var resultSent = false
    private var cameraStarted = false
    private var frameCounter = 0

    // Written on the main thread, read on the capture-processing thread.
    @Volatile private var lastFaceBox: Rect? = null
    @Volatile private var lastFrameWidth = 0
    @Volatile private var lastFrameHeight = 0

    override val lifecycle: Lifecycle
        get() = lifecycleRegistry

    init {
        previewView.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        previewView.scaleType = PreviewView.ScaleType.FILL_CENTER
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "cancel" -> {
                    onCancel()
                    result.success(null)
                }
                "restart" -> {
                    onRestart()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        lifecycleRegistry.currentState = Lifecycle.State.CREATED
        lifecycleRegistry.currentState = Lifecycle.State.STARTED
        lifecycleRegistry.currentState = Lifecycle.State.RESUMED
        mainHandler.post { start() }
    }

    override fun getView(): View = previewView

    override fun dispose() {
        if (disposed) return
        disposed = true
        session?.stop()
        session = null
        channel.setMethodCallHandler(null)
        try {
            cameraProvider?.unbindAll()
        } catch (_: Exception) {
        }
        lifecycleRegistry.currentState = Lifecycle.State.DESTROYED
        faceDetector?.close()
        faceDetector = null
        analysisExecutor.shutdown()
    }

    // -------------------------------------------------------------- lifecycle

    private fun start() {
        if (disposed) return
        if (hasCameraPermission()) {
            startCamera()
            startSession()
            return
        }
        plugin.requestCameraPermission { granted ->
            if (disposed) return@requestCameraPermission
            if (granted) {
                startCamera()
                startSession()
            } else {
                postFailureResult("cameraError", delayMs = EARLY_RESULT_DELAY_MS)
            }
        }
    }

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(appContext, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private fun startSession() {
        session?.stop()
        antiSpoof.reset()
        session = ChallengeSession(buildChallengeList(), config.challengeTimeoutMs, this)
    }

    private fun buildChallengeList(): List<String> {
        val pool = config.challengePool
        val n = config.numberOfChallenges
        val out = ArrayList<String>(n)
        // Draw without repeats until the pool is exhausted; repeat rounds when
        // more challenges than pool entries were requested.
        while (out.size < n) {
            val round = if (config.randomizeOrder) pool.shuffled() else pool
            out += round.take(n - out.size)
        }
        return out
    }

    private fun startCamera() {
        if (cameraStarted || disposed) return
        cameraStarted = true
        createFaceDetector()
        val future = ProcessCameraProvider.getInstance(appContext)
        future.addListener({
            if (disposed) return@addListener
            try {
                val provider = future.get()
                cameraProvider = provider
                bindUseCases(provider)
            } catch (e: Exception) {
                postFailureResult("cameraError")
            }
        }, ContextCompat.getMainExecutor(appContext))
    }

    private fun createFaceDetector() {
        val options = FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_ALL)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
            .setMinFaceSize(0.15f)
            .enableTracking()
            .build()
        faceDetector = FaceDetection.getClient(options)
    }

    private fun bindUseCases(provider: ProcessCameraProvider) {
        val selector = if (config.cameraLensDirection == "back") {
            CameraSelector.DEFAULT_BACK_CAMERA
        } else {
            CameraSelector.DEFAULT_FRONT_CAMERA
        }

        val preview = Preview.Builder().build()
        preview.setSurfaceProvider(previewView.surfaceProvider)

        val analysisResolution = ResolutionSelector.Builder()
            .setResolutionStrategy(
                ResolutionStrategy(
                    Size(640, 480),
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                ),
            )
            .build()
        val analysis = ImageAnalysis.Builder()
            .setResolutionSelector(analysisResolution)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
        analysis.setAnalyzer(analysisExecutor) { proxy -> analyzeFrame(proxy) }

        val capture = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
            .build()
        imageCapture = capture

        try {
            provider.unbindAll()
            provider.bindToLifecycle(this, selector, preview, analysis, capture)
        } catch (e: Exception) {
            postFailureResult("cameraError")
        }
    }

    // --------------------------------------------------------------- analysis

    @androidx.annotation.OptIn(ExperimentalGetImage::class)
    private fun analyzeFrame(proxy: ImageProxy) {
        val detector = faceDetector
        val mediaImage = proxy.image
        if (disposed || resultSent || detector == null || mediaImage == null) {
            proxy.close()
            return
        }
        val rotation = proxy.imageInfo.rotationDegrees
        val swapped = rotation == 90 || rotation == 270
        val frameWidth = if (swapped) proxy.height else proxy.width
        val frameHeight = if (swapped) proxy.width else proxy.height
        val meanLuma = computeMeanLuma(proxy)
        frameCounter++
        val lumaCrop =
            if (config.enablePassiveAntiSpoof && frameCounter % TEXTURE_SAMPLE_EVERY == 0) {
                grabLumaCrop(proxy)
            } else {
                null
            }
        val timestamp = SystemClock.elapsedRealtime()
        detector.process(InputImage.fromMediaImage(mediaImage, rotation))
            .addOnSuccessListener { faces ->
                // ML Kit delivers this on the main thread.
                if (!disposed) {
                    handleFaces(faces, frameWidth, frameHeight, meanLuma, lumaCrop, timestamp)
                }
            }
            .addOnCompleteListener { proxy.close() }
    }

    private fun handleFaces(
        faces: List<Face>,
        frameWidth: Int,
        frameHeight: Int,
        meanLuma: Double,
        lumaCrop: LumaCrop?,
        timestampMs: Long,
    ) {
        if (resultSent) return
        val obs = if (faces.size == 1) {
            val face = faces[0]
            lastFaceBox = Rect(face.boundingBox)
            lastFrameWidth = frameWidth
            lastFrameHeight = frameHeight
            val landmarks = HashMap<Int, PointF>()
            for (type in intArrayOf(
                FaceLandmark.NOSE_BASE,
                FaceLandmark.LEFT_CHEEK,
                FaceLandmark.RIGHT_CHEEK,
                FaceLandmark.LEFT_EYE,
                FaceLandmark.RIGHT_EYE,
                FaceLandmark.MOUTH_BOTTOM,
            )) {
                face.getLandmark(type)?.let { landmarks[type] = it.position }
            }
            FaceObservation(
                timestampMs = timestampMs,
                frameWidth = frameWidth,
                frameHeight = frameHeight,
                faceCount = 1,
                meanLuma = meanLuma,
                boundingBox = face.boundingBox,
                eulerX = face.headEulerAngleX,
                eulerY = face.headEulerAngleY,
                eulerZ = face.headEulerAngleZ,
                leftEyeOpenProb = face.leftEyeOpenProbability,
                rightEyeOpenProb = face.rightEyeOpenProbability,
                smileProb = face.smilingProbability,
                landmarks = landmarks,
            )
        } else {
            FaceObservation(timestampMs, frameWidth, frameHeight, faces.size, meanLuma)
        }
        if (config.enablePassiveAntiSpoof) antiSpoof.onObservation(obs, lumaCrop)
        session?.onFrame(obs)
    }

    /** Mean luminance (0-255) of the central half of the frame's Y plane. */
    private fun computeMeanLuma(proxy: ImageProxy): Double {
        val plane = proxy.planes.getOrNull(0) ?: return 255.0
        val buffer = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val x0 = proxy.width / 4
        val x1 = proxy.width * 3 / 4
        val y0 = proxy.height / 4
        val y1 = proxy.height * 3 / 4
        var sum = 0L
        var count = 0
        var y = y0
        while (y < y1) {
            var x = x0
            while (x < x1) {
                val index = y * rowStride + x * pixelStride
                if (index < buffer.limit()) {
                    sum += buffer.get(index).toInt() and 0xFF
                    count++
                }
                x += 8
            }
            y += 8
        }
        return if (count == 0) 255.0 else sum.toDouble() / count
    }

    /** 64x64 nearest-neighbor luma crop of the central half of the frame. */
    private fun grabLumaCrop(proxy: ImageProxy): LumaCrop? {
        val plane = proxy.planes.getOrNull(0) ?: return null
        val buffer = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val size = 64
        val regionW = proxy.width / 2
        val regionH = proxy.height / 2
        if (regionW < size || regionH < size) return null
        val startX = proxy.width / 4
        val startY = proxy.height / 4
        val data = ByteArray(size * size)
        for (j in 0 until size) {
            val srcY = startY + j * regionH / size
            for (i in 0 until size) {
                val srcX = startX + i * regionW / size
                val index = srcY * rowStride + srcX * pixelStride
                if (index < buffer.limit()) data[j * size + i] = buffer.get(index)
            }
        }
        return LumaCrop(size, size, data)
    }

    // ------------------------------------------------------ session callbacks

    override fun onSessionEvent(event: Map<String, Any>) {
        if (disposed || resultSent) return
        channel.invokeMethod("onEvent", event)
    }

    override fun onChallengesPassed(completed: List<String>) {
        if (disposed || resultSent) return
        onSessionEvent(mapOf("type" to "hint", "code" to "holdStill"))
        val score: Double? =
            if (config.enablePassiveAntiSpoof) antiSpoof.computeScore() else null
        if (score != null && score < config.spoofScoreThreshold) {
            sendResult(
                mapOf(
                    "success" to false,
                    "failureReason" to "spoofDetected",
                    "spoofScore" to score,
                    "completed" to completed,
                ),
            )
            return
        }
        captureAndFinish(score, completed)
    }

    override fun onSessionFailed(reason: String, completed: List<String>) {
        if (disposed) return
        sendResult(failureMap(reason, completed))
    }

    // ---------------------------------------------------------------- capture

    private fun captureAndFinish(score: Double?, completed: List<String>) {
        val capture = imageCapture
        if (capture == null) {
            sendResult(failureMap("cameraError", completed, score))
            return
        }
        capture.takePicture(
            ContextCompat.getMainExecutor(appContext),
            object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: ImageProxy) {
                    val buffer = image.planes[0].buffer
                    val jpegBytes = ByteArray(buffer.remaining())
                    buffer.get(jpegBytes)
                    val rotation = image.imageInfo.rotationDegrees
                    image.close()
                    try {
                        analysisExecutor.execute {
                            val map = try {
                                buildSuccessResult(jpegBytes, rotation, score, completed)
                            } catch (e: Exception) {
                                failureMap("unknown", completed, score)
                            }
                            mainHandler.post { sendResult(map) }
                        }
                    } catch (e: Exception) {
                        sendResult(failureMap("unknown", completed, score))
                    }
                }

                override fun onError(exception: ImageCaptureException) {
                    sendResult(failureMap("cameraError", completed, score))
                }
            },
        )
    }

    private fun buildSuccessResult(
        jpegBytes: ByteArray,
        rotationDegrees: Int,
        score: Double?,
        completed: List<String>,
    ): Map<String, Any?> {
        var bitmap = BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.size)
            ?: return failureMap("unknown", completed, score)
        if (rotationDegrees != 0) {
            val matrix = Matrix().apply { postRotate(rotationDegrees.toFloat()) }
            bitmap = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        }
        val cropped = cropAroundFace(bitmap)
        val out = ByteArrayOutputStream()
        cropped.compress(Bitmap.CompressFormat.JPEG, config.imageQuality, out)
        val base64 = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
        return mapOf(
            "success" to true,
            "imageBase64" to base64,
            "imageWidth" to cropped.width,
            "imageHeight" to cropped.height,
            "spoofScore" to score,
            "completed" to completed,
        )
    }

    /**
     * Crops the upright capture around the last analysis-frame face box,
     * expanded to twice the face size (a "generous" crop per the contract).
     * Falls back to the full frame when the mapping is unavailable.
     */
    private fun cropAroundFace(bitmap: Bitmap): Bitmap {
        val box = lastFaceBox ?: return bitmap
        val frameW = lastFrameWidth
        val frameH = lastFrameHeight
        if (frameW <= 0 || frameH <= 0) return bitmap
        val scaleX = bitmap.width.toDouble() / frameW
        val scaleY = bitmap.height.toDouble() / frameH
        val centerX = box.exactCenterX() * scaleX
        val centerY = box.exactCenterY() * scaleY
        val halfW = box.width() * scaleX // crop width = 2x face width
        val halfH = box.height() * scaleY // crop height = 2x face height
        val left = max(0.0, centerX - halfW).roundToInt()
        val top = max(0.0, centerY - halfH).roundToInt()
        val right = min(bitmap.width.toDouble(), centerX + halfW).roundToInt()
        val bottom = min(bitmap.height.toDouble(), centerY + halfH).roundToInt()
        if (right - left < 32 || bottom - top < 32) return bitmap
        return Bitmap.createBitmap(bitmap, left, top, right - left, bottom - top)
    }

    // ----------------------------------------------------------- Dart -> view

    private fun onCancel() {
        val completed = session?.completedChallenges ?: emptyList()
        session?.stop()
        sendResult(failureMap("cancelled", completed))
    }

    private fun onRestart() {
        // The Dart layer latches the first onResult per view, so restarting
        // after a terminal result would go nowhere; only pre-terminal restarts
        // are honoured.
        if (resultSent || disposed) return
        startSession()
    }

    // ---------------------------------------------------------------- results

    private fun failureMap(
        reason: String,
        completed: List<String>,
        score: Double? = null,
    ): Map<String, Any?> = mapOf(
        "success" to false,
        "failureReason" to reason,
        "spoofScore" to score,
        "completed" to completed,
    )

    private fun postFailureResult(reason: String, delayMs: Long = 0L) {
        val completed = session?.completedChallenges ?: emptyList()
        val map = failureMap(reason, completed)
        if (delayMs > 0) {
            mainHandler.postDelayed({ sendResult(map) }, delayMs)
        } else {
            mainHandler.post { sendResult(map) }
        }
    }

    /** Emits the terminal `onResult` exactly once, on the main thread. */
    private fun sendResult(map: Map<String, Any?>) {
        if (resultSent || disposed) return
        resultSent = true
        session?.stop()
        channel.invokeMethod("onResult", map)
    }
}
