package com.trueface.trueface_liveness

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.PointF
import android.graphics.Rect
import android.graphics.YuvImage
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.util.Size
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
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
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import java.io.File
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
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.security.SecureRandom
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

import dev.trueface.liveness.ChallengeSession
import dev.trueface.liveness.AntiSpoofDetector
import dev.trueface.liveness.FaceObservation
import dev.trueface.liveness.LumaCrop


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
    val recordVideo: Boolean,
    val videoMaxDurationMs: Long,
    val showInstructions: Boolean?,
    val flashColors: List<String>,
    val flashDurationMs: Long,
    val backendBaseUrl: String?,
    val publicKey: String?,
    val verificationId: String?,
    val clientSecret: String?,
    val colorsMap: Map<*, *>?
) {
    val hasBackend: Boolean
        get() = !backendBaseUrl.isNullOrBlank() &&
                !publicKey.isNullOrBlank() &&
                !verificationId.isNullOrBlank() &&
                !clientSecret.isNullOrBlank()

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
                recordVideo = map["recordVideo"] as? Boolean ?: false,
                videoMaxDurationMs = (map["videoMaxDurationMs"] as? Number)?.toLong() ?: 3000L,
                showInstructions = map["showInstructions"] as? Boolean,
                flashColors = (map["flashColors"] as? List<*>)?.filterIsInstance<String>().orEmpty(),
                flashDurationMs = (map["flashDurationMs"] as? Number)?.toLong() ?: 150L,
                backendBaseUrl = (map["backendBaseUrl"] as? String) ?: "https://api.trueface.dev",
                publicKey = map["publicKey"] as? String,
                verificationId = map["verificationId"] as? String,
                clientSecret = map["clientSecret"] as? String,
                colorsMap = map["colors"] as? Map<*, *>
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
    private val plugin: TrueFaceLivenessPlugin,
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
    private val channel = MethodChannel(messenger, "com.trueface/trueface_liveness_$viewId")
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

    // Video recording (hosted verification). When [config.recordVideo] is on we
    // bind VideoCapture instead of ImageCapture and take the final still from a
    // cached single-face analysis frame.
    private var videoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    @Volatile private var videoFile: File? = null
    @Volatile private var videoFinalized = false
    @Volatile private var lastFrameJpeg: ByteArray? = null
    @Volatile private var lastFrameJpegRotation = 0
    @Volatile private var bestAttentiveJpeg: ByteArray? = null
    @Volatile private var bestAttentiveRotation = 0
    @Volatile private var bestAttentiveScore = -1f
    @Volatile private var bestEyesOpenJpeg: ByteArray? = null
    @Volatile private var bestEyesOpenRotation = 0
    @Volatile private var bestEyesOpenScore = -1f

    private var dynamicChallenges: List<String>? = null
    private var dynamicFlashColors: List<String> = emptyList()
    private var dynamicFlashDurationMs: Long = 200L

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
        if (!resultSent) stopAndDiscardVideo() else recording = null
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

    private fun fetchBackendSessionConfig(onReady: () -> Unit) {
        if (!config.hasBackend) {
            onReady()
            return
        }
        val backendUrl = config.backendBaseUrl?.removeSuffix("/") ?: run { onReady(); return }
        val verificationId = config.verificationId ?: run { onReady(); return }
        val publicKey = config.publicKey ?: run { onReady(); return }
        val clientSecret = config.clientSecret ?: run { onReady(); return }

        val client = OkHttpClient()
        val req = Request.Builder()
            .url("$backendUrl/v1/sessions/$verificationId/start")
            .post(JSONObject().put("clientSecret", clientSecret).toString().toRequestBody("application/json".toMediaType()))
            .addHeader("x-public-key", publicKey)
            .addHeader("x-client-secret", clientSecret)
            .build()

        client.newCall(req).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                mainHandler.post { onReady() }
            }

            override fun onResponse(call: Call, response: Response) {
                try {
                    val respStr = response.body?.string() ?: "{}"
                    val json = JSONObject(respStr)
                    val challengesJson = json.optJSONArray("challenges")
                    if (challengesJson != null && challengesJson.length() > 0) {
                        val list = mutableListOf<String>()
                        for (i in 0 until challengesJson.length()) {
                            list.add(challengesJson.getString(i))
                        }
                        dynamicChallenges = list
                    }
                    val flashObj = json.optJSONObject("flashConfig")
                    if (flashObj != null && flashObj.optBoolean("enabled", false)) {
                        dynamicFlashDurationMs = flashObj.optLong("durationMsPerColor", 200L)
                        val colorsArr = flashObj.optJSONArray("colors")
                        if (colorsArr != null && colorsArr.length() > 0) {
                            val list = mutableListOf<String>()
                            for (i in 0 until colorsArr.length()) {
                                list.add(colorsArr.getString(i))
                            }
                            dynamicFlashColors = list
                        }
                    }
                } catch (_: Exception) {}
                mainHandler.post { onReady() }
            }
        })
    }

    private val activeFlashColors: List<String>
        get() = if (config.flashColors.isNotEmpty()) config.flashColors else dynamicFlashColors

    private val activeFlashDurationMs: Long
        get() = if (config.flashColors.isNotEmpty()) config.flashDurationMs else dynamicFlashDurationMs

    private fun start() {
        if (disposed) return
        if (hasCameraPermission()) {
            startCamera()
            fetchBackendSessionConfig {
                if (!disposed) startSession()
            }
            return
        }
        plugin.requestCameraPermission { granted ->
            if (disposed) return@requestCameraPermission
            if (granted) {
                startCamera()
                fetchBackendSessionConfig {
                    if (!disposed) startSession()
                }
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
        bestAttentiveJpeg = null
        bestAttentiveScore = -1f
        bestEyesOpenJpeg = null
        bestEyesOpenScore = -1f
        lastFrameJpeg = null
        session = ChallengeSession(buildChallengeList(), config.challengeTimeoutMs, this)
    }

    private fun buildChallengeList(): List<String> {
        val dynamic = dynamicChallenges
        if (!dynamic.isNullOrEmpty()) {
            return dynamic
        }
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
            .setContourMode(FaceDetectorOptions.CONTOUR_MODE_ALL)
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

        // When recording, source the final still from the analysis stream, so
        // use a higher analysis resolution for acceptable still quality.
        val targetSize = Size(640, 480)
        val analysisResolution = ResolutionSelector.Builder()
            .setResolutionStrategy(
                ResolutionStrategy(
                    targetSize,
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                ),
            )
            .build()
        val analysis = ImageAnalysis.Builder()
            .setResolutionSelector(analysisResolution)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
        analysis.setAnalyzer(analysisExecutor) { proxy -> analyzeFrame(proxy) }

        try {
            provider.unbindAll()
            if (config.recordVideo) {
                // CameraX cannot reliably bind 4 use cases; drop ImageCapture
                // and record with VideoCapture (Preview + Analysis + Video).
                val recorder = Recorder.Builder()
                    .setQualitySelector(
                        QualitySelector.from(
                            Quality.SD,
                            FallbackStrategy.lowerQualityOrHigherThan(Quality.SD),
                        ),
                    )
                    .build()
                val vc = VideoCapture.withOutput(recorder)
                videoCapture = vc
                provider.bindToLifecycle(this, selector, preview, analysis, vc)
            } else {
                val capture = ImageCapture.Builder()
                    .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
                    .build()
                imageCapture = capture
                provider.bindToLifecycle(this, selector, preview, analysis, capture)
            }
        } catch (e: Exception) {
            postFailureResult("cameraError")
        }
    }

    private fun startVideoRecording() {
        val vc = videoCapture ?: return
        if (recording != null) return
        videoFinalized = false
        lastFrameJpeg = null
        val file = File(appContext.cacheDir, "liveness_${System.currentTimeMillis()}.mp4")
        videoFile = file
        val options = FileOutputOptions.Builder(file)
            .setDurationLimitMillis(config.videoMaxDurationMs)
            .build()
        // No .withAudioEnabled() — video only, so no RECORD_AUDIO permission.
        recording = vc.output
            .prepareRecording(appContext, options)
            .start(ContextCompat.getMainExecutor(appContext)) { event ->
                if (event is VideoRecordEvent.Finalize) videoFinalized = true
            }
    }

    // ---------------------------------------------------------------- analysis

    @androidx.annotation.OptIn(ExperimentalGetImage::class)
    private fun analyzeFrame(proxy: ImageProxy) {
        if (disposed || resultSent) {
            proxy.close()
            return
        }
        val mediaImage = proxy.image
        if (mediaImage == null) {
            proxy.close()
            return
        }
        val rotation = proxy.imageInfo.rotationDegrees
        val image = InputImage.fromMediaImage(mediaImage, rotation)
        val detector = faceDetector
        if (detector == null) {
            proxy.close()
            return
        }
        val frameWidth = if (rotation == 90 || rotation == 270) proxy.height else proxy.width
        val frameHeight = if (rotation == 90 || rotation == 270) proxy.width else proxy.height
        val meanLuma = computeMeanLuma(proxy)
        val lumaCrop =
            if (frameCounter++ % TEXTURE_SAMPLE_EVERY == 0) grabLumaCrop(proxy) else null
        val now = SystemClock.elapsedRealtime()

        val frameJpeg = encodeProxyToJpeg(proxy)

        detector.process(image)
            .addOnSuccessListener(analysisExecutor) { faces ->
                processObservation(
                    faces = faces,
                    frameWidth = frameWidth,
                    frameHeight = frameHeight,
                    meanLuma = meanLuma,
                    lumaCrop = lumaCrop,
                    timestampMs = now,
                    frameJpeg = frameJpeg,
                    frameRotation = rotation,
                )
            }
            .addOnCompleteListener { proxy.close() }
    }

    private fun processObservation(
        faces: List<Face>,
        frameWidth: Int,
        frameHeight: Int,
        meanLuma: Double,
        lumaCrop: LumaCrop?,
        timestampMs: Long,
        frameJpeg: ByteArray?,
        frameRotation: Int,
    ) {
        if (resultSent) return
        val obs = if (faces.size == 1) {
            val face = faces[0]
            lastFaceBox = Rect(face.boundingBox)
            lastFrameWidth = frameWidth
            lastFrameHeight = frameHeight

            val leftEyeOpen = face.leftEyeOpenProbability ?: 0.8f
            val rightEyeOpen = face.rightEyeOpenProbability ?: 0.8f
            val absY = kotlin.math.abs(face.headEulerAngleY)
            val absX = kotlin.math.abs(face.headEulerAngleX)

            if (frameJpeg != null) {
                lastFrameJpeg = frameJpeg
                lastFrameJpegRotation = frameRotation

                // Evaluate face attentiveness (eyes open >= 0.70, head frontal <= 12 deg)
                if (leftEyeOpen >= 0.70f && rightEyeOpen >= 0.70f && absY <= 12f && absX <= 12f) {
                    val score = (leftEyeOpen + rightEyeOpen) - (absY + absX) / 100f
                    if (score > bestAttentiveScore) {
                        bestAttentiveScore = score
                        bestAttentiveJpeg = frameJpeg
                        bestAttentiveRotation = frameRotation
                    }
                }

                val eyesScore = leftEyeOpen + rightEyeOpen
                if (eyesScore > bestEyesOpenScore) {
                    bestEyesOpenScore = eyesScore
                    bestEyesOpenJpeg = frameJpeg
                    bestEyesOpenRotation = frameRotation
                }
            }
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

            var mouthOpenScore: Float? = null
            val upperLip = face.getContour(com.google.mlkit.vision.face.FaceContour.UPPER_LIP_BOTTOM)?.points
            val lowerLip = face.getContour(com.google.mlkit.vision.face.FaceContour.LOWER_LIP_TOP)?.points
            val mouthLeft = face.getLandmark(FaceLandmark.MOUTH_LEFT)?.position
            val mouthRight = face.getLandmark(FaceLandmark.MOUTH_RIGHT)?.position
            val mouthBottom = face.getLandmark(FaceLandmark.MOUTH_BOTTOM)?.position
            val noseBase = face.getLandmark(FaceLandmark.NOSE_BASE)?.position

            if (!upperLip.isNullOrEmpty() && !lowerLip.isNullOrEmpty()) {
                val topP = upperLip[upperLip.size / 2]
                val botP = lowerLip[lowerLip.size / 2]
                val innerH = kotlin.math.hypot((botP.x - topP.x).toDouble(), (botP.y - topP.y).toDouble()).toFloat()
                val mouthW = if (mouthLeft != null && mouthRight != null) {
                    kotlin.math.hypot((mouthRight.x - mouthLeft.x).toDouble(), (mouthRight.y - mouthLeft.y).toDouble()).toFloat()
                } else {
                    face.boundingBox.width().toFloat() * 0.4f
                }
                mouthOpenScore = if (mouthW > 0) (innerH / mouthW) else 0f
            } else if (mouthBottom != null && noseBase != null) {
                val mouthDist = kotlin.math.hypot((mouthBottom.x - noseBase.x).toDouble(), (mouthBottom.y - noseBase.y).toDouble()).toFloat()
                val faceH = face.boundingBox.height().toFloat().coerceAtLeast(1f)
                mouthOpenScore = (mouthDist / faceH).coerceAtLeast(0f)
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
                mouthOpenProb = mouthOpenScore,
                landmarks = landmarks,
            )
        } else {
            FaceObservation(timestampMs, frameWidth, frameHeight, faces.size, meanLuma)
        }
        if (config.enablePassiveAntiSpoof) antiSpoof.onObservation(obs, lumaCrop)
        session?.onFrame(obs)
    }

    /** Mean luminance (0-255) of the central half of the frame's Y plane with glare saturation detection. */
    private fun computeMeanLuma(proxy: ImageProxy): Double {
        val plane = proxy.planes.getOrNull(0) ?: return 120.0
        val buffer = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val w = proxy.width
        val h = proxy.height
        val x0 = w / 4
        val x1 = (3 * w) / 4
        val y0 = h / 4
        val y1 = (3 * h) / 4

        var sum = 0L
        var count = 0
        var saturatedCount = 0
        var y = y0
        while (y < y1) {
            var x = x0
            while (x < x1) {
                val index = y * rowStride + x * pixelStride
                if (index < buffer.limit()) {
                    val luma = buffer.get(index).toInt() and 0xFF
                    sum += luma
                    if (luma >= 250) saturatedCount++
                    count++
                }
                x += 8
            }
            y += 8
        }
        if (count == 0) return 120.0
        // Glare / Overexposure Gating: If >25% of facial pixels are saturated, report 245 to trigger faceTooBright
        if (saturatedCount.toDouble() / count > 0.25) return 245.0
        return sum.toDouble() / count
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
        mainHandler.post {
            if (disposed || resultSent) return@post
            if (event["type"] == "challengeStarted" && config.recordVideo && recording == null) {
                startVideoRecording()
            }
            channel.invokeMethod("onEvent", event)
        }
    }

    override fun onChallengesPassed(completed: List<String>) {
        if (disposed || resultSent) return
        mainHandler.post {
            if (disposed || resultSent) return@post
            val score: Double? =
                if (config.enablePassiveAntiSpoof) antiSpoof.computeScore() else null
            if (score != null && score < config.spoofScoreThreshold) {
                if (config.recordVideo) stopAndDiscardVideo()
                sendResult(
                    mapOf(
                        "success" to false,
                        "failureReason" to "spoofDetected",
                        "spoofScore" to score,
                        "completed" to completed,
                    ),
                )
                return@post
            }

            val colorsToFlash = activeFlashColors
            if (colorsToFlash.isNotEmpty()) {
                runFlashChallenge(colorsToFlash, activeFlashDurationMs) {
                    captureAndFinish(score, completed)
                }
            } else {
                captureAndFinish(score, completed)
            }
        }
    }

    private fun runFlashChallenge(colorsList: List<String>, durationMs: Long, onComplete: () -> Unit) {
        val colors = colorsList.mapNotNull { hex ->
            try { Color.parseColor(hex) } catch (_: Exception) { null }
        }
        if (colors.isEmpty()) {
            onComplete()
            return
        }

        channel.invokeMethod("onEvent", mapOf("type" to "instruction", "instruction" to "Hold steady — analyzing reflection..."))

        val targetView = (previewView.rootView as? ViewGroup) ?: previewView
        val flashOverlay = View(targetView.context).apply {
            setBackgroundColor(Color.TRANSPARENT)
            layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            isClickable = false
            isFocusable = false
        }
        targetView.addView(flashOverlay)
        flashOverlay.bringToFront()

        fun finishFlash() {
            try {
                targetView.removeView(flashOverlay)
            } catch (_: Exception) {}
            onComplete()
        }

        fun flashStep(index: Int) {
            if (index >= colors.size) {
                finishFlash()
                return
            }

            val color = colors[index]
            val semiTransparent = Color.argb(125, Color.red(color), Color.green(color), Color.blue(color))
            flashOverlay.setBackgroundColor(semiTransparent)

            mainHandler.postDelayed({
                flashStep(index + 1)
            }, durationMs)
        }

        flashStep(0)
    }

    override fun onSessionFailed(reason: String, completed: List<String>) {
        if (disposed) return
        mainHandler.post {
            if (disposed) return@post
            if (config.recordVideo) stopAndDiscardVideo()
            sendResult(failureMap(reason, completed))
        }
    }

    // ---------------------------------------------------------------- capture

    private fun captureAndFinish(score: Double?, completed: List<String>) {
        if (config.recordVideo) {
            finishWithRecording(score, completed)
            return
        }
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
                            mainHandler.post {
                                if (config.hasBackend && (map["success"] as? Boolean) == true) {
                                    performNativeHostedVerification(map, score, completed)
                                } else {
                                    sendResult(map)
                                }
                            }
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

    /**
     * Stops recording, waits for the file to finalize, then builds the result
     * from the cached single-face frame with the video path attached.
     */
    private fun finishWithRecording(score: Double?, completed: List<String>) {
        recording?.stop()
        analysisExecutor.execute {
            val deadline = SystemClock.elapsedRealtime() + 2000
            while (!videoFinalized && SystemClock.elapsedRealtime() < deadline) {
                Thread.sleep(50)
            }
            val jpeg = bestAttentiveJpeg ?: bestEyesOpenJpeg ?: lastFrameJpeg
            val rotation = if (bestAttentiveJpeg != null) bestAttentiveRotation else if (bestEyesOpenJpeg != null) bestEyesOpenRotation else lastFrameJpegRotation
            val map: Map<String, Any?> = if (jpeg != null) {
                val base = try {
                    buildSuccessResult(jpeg, rotation, score, completed)
                } catch (e: Exception) {
                    failureMap("unknown", completed, score)
                }
                base.toMutableMap().apply {
                    videoFile?.let { if (it.exists()) put("videoPath", it.absolutePath) }
                }
            } else {
                failureMap("unknown", completed, score)
            }
            mainHandler.post {
                if (config.hasBackend && (map["success"] as? Boolean) == true) {
                    performNativeHostedVerification(map, score, completed)
                } else {
                    sendResult(map)
                }
            }
        }
    }

    private fun performNativeHostedVerification(resultMap: Map<String, Any?>, score: Double?, completed: List<String>) {
        val backendUrl = config.backendBaseUrl?.removeSuffix("/") ?: return
        val verificationId = config.verificationId ?: return
        val publicKey = config.publicKey ?: return
        val clientSecret = config.clientSecret ?: return

        val imageBase64 = resultMap["imageBase64"] as? String
        val imageBytes = if (imageBase64 != null) Base64.decode(imageBase64, Base64.DEFAULT) else null

        val videoPath = resultMap["videoPath"] as? String
        val videoFile = if (videoPath != null) File(videoPath) else null
        val videoBytes = if (videoFile != null && videoFile.exists()) videoFile.readBytes() else null

        dev.trueface.liveness.HostedVerificationClient.performVerification(
            backendUrl = backendUrl,
            verificationId = verificationId,
            publicKey = publicKey,
            clientSecret = clientSecret,
            imageBytes = imageBytes,
            videoBytes = videoBytes,
            completedChallenges = completed,
            onDeviceSpoofScore = score,
            callback = object : dev.trueface.liveness.HostedVerificationClient.VerificationCallback {
                override fun onProgress(type: String, progress: Double) {
                    mainHandler.post {
                        channel.invokeMethod("onEvent", mapOf("type" to type, "progress" to progress))
                    }
                }

                override fun onSuccess(verificationStatus: String) {
                    val finalMap = resultMap.toMutableMap()
                    finalMap["verificationStatus"] = verificationStatus
                    finalMap["success"] = (verificationStatus == "approved" || verificationStatus == "completed" || verificationStatus == "processing")
                    mainHandler.post { sendResult(finalMap) }
                }

                override fun onError(reason: String, message: String?) {
                    mainHandler.post { sendResult(failureMap(reason, completed, score)) }
                }
            }
        )
    }

    /** Stops recording and deletes the temp file — used on failure/cancel. */
    private fun stopAndDiscardVideo() {
        try {
            recording?.stop()
            recording = null
            videoFile?.delete()
            videoFile = null
        } catch (_: Exception) {
        }
    }

    /** Encodes a YUV_420_888 [ImageProxy] to an unrotated JPEG. */
    @androidx.annotation.OptIn(ExperimentalGetImage::class)
    private fun encodeProxyToJpeg(proxy: ImageProxy): ByteArray? {
        val image = proxy.image ?: return null
        if (image.format != ImageFormat.YUV_420_888) return null
        return try {
            val nv21 = yuv420ToNv21(proxy)
            val yuv = YuvImage(nv21, ImageFormat.NV21, proxy.width, proxy.height, null)
            val out = ByteArrayOutputStream()
            yuv.compressToJpeg(Rect(0, 0, proxy.width, proxy.height), 95, out)
            out.toByteArray()
        } catch (e: Exception) {
            null
        }
    }

    private fun yuv420ToNv21(proxy: ImageProxy): ByteArray {
        val width = proxy.width
        val height = proxy.height
        val ySize = width * height
        val nv21 = ByteArray(ySize + ySize / 2)

        val yPlane = proxy.planes[0]
        val uPlane = proxy.planes[1]
        val vPlane = proxy.planes[2]

        // Y
        var pos = 0
        val yBuffer = yPlane.buffer
        val yRowStride = yPlane.rowStride
        val yPixelStride = yPlane.pixelStride
        for (row in 0 until height) {
            var col = 0
            var yIndex = row * yRowStride
            while (col < width) {
                nv21[pos++] = yBuffer.get(yIndex)
                yIndex += yPixelStride
                col++
            }
        }

        // VU interleaved (NV21 = Y + VU)
        val uBuffer = uPlane.buffer
        val vBuffer = vPlane.buffer
        val uRowStride = uPlane.rowStride
        val uPixelStride = uPlane.pixelStride
        val vRowStride = vPlane.rowStride
        val vPixelStride = vPlane.pixelStride
        val chromaHeight = height / 2
        val chromaWidth = width / 2
        for (row in 0 until chromaHeight) {
            var uIndex = row * uRowStride
            var vIndex = row * vRowStride
            for (col in 0 until chromaWidth) {
                nv21[pos++] = vBuffer.get(vIndex)
                nv21[pos++] = uBuffer.get(uIndex)
                uIndex += uPixelStride
                vIndex += vPixelStride
            }
        }
        return nv21
    }

    // ----------------------------------------------------------- Dart -> view

    private fun onCancel() {
        val completed = session?.completedChallenges ?: emptyList()
        session?.stop()
        if (config.recordVideo) stopAndDiscardVideo()
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
        mainHandler.post {
            channel.invokeMethod("onResult", map)
        }
    }
}
