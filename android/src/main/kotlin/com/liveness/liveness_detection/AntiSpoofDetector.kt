package com.liveness.liveness_detection

import com.google.mlkit.vision.face.FaceLandmark
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Pluggable passive anti-spoof scoring.
 *
 * Implementations receive every analyzed frame during the session and, once
 * all active challenges have passed, produce a "realness" score in 0..1
 * (higher = more likely a live, physically present face).
 */
interface AntiSpoofDetector {

    /** Called on the main thread for every analyzed frame of the session. */
    fun onObservation(obs: FaceObservation, lumaCrop: LumaCrop?)

    /** Realness score in 0..1 for everything observed so far. */
    fun computeScore(): Double

    /** Clears accumulated state (called on `restart`). */
    fun reset()

    companion object {
        /**
         * Returns the detector used for the session.
         *
         * TODO(tflite): production-grade slot. To use a silent-face anti-spoof
         * model (e.g. MiniVision MiniFASNet):
         *   1. Put the model at `android/src/main/assets/anti_spoof.tflite`.
         *   2. Add `implementation("org.tensorflow:tensorflow-lite:<version>")`
         *      to `android/build.gradle.kts`.
         *   3. Implement [AntiSpoofDetector] backed by the interpreter (feed it
         *      the face crop from each [LumaCrop]/frame and average the logits).
         *   4. Detect the asset here (`context.assets.open(...)`) and return
         *      that implementation in preference to [HeuristicAntiSpoofDetector].
         * The heuristic below intentionally requires NO extra model files.
         */
        fun create(): AntiSpoofDetector = HeuristicAntiSpoofDetector()
    }
}

/**
 * Default model-free heuristic. It combines three cues, each mapped to 0..1,
 * into a weighted average:
 *
 * 1. **Depth-from-motion parallax (weight 0.55).** During the head-turn
 *    challenges the nose tip of a real 3-D head (near the camera, off the
 *    rotation axis) translates horizontally *relative to* the far/on-axis
 *    landmarks (cheeks / box center) roughly proportionally to sin(yaw). A
 *    flat photo or screen moves affinely: the nose keeps a fixed position
 *    inside the face box regardless of the reported yaw. We fit the slope of
 *    normalized nose offset vs sin(yaw) over the session; |slope| >= ~0.20
 *    (a typical real-head value) scores 1.0, 0 scores 0.0.
 *
 * 2. **Micro-motion (weight 0.25).** A live subject can never hold the
 *    normalized nose position perfectly still between consecutive frames; a
 *    photo on a stand can. The median inter-frame displacement (normalized by
 *    frame size) reaches 1.0 at >= 0.15% of the frame per frame.
 *
 * 3. **Texture (weight 0.20).** High-frequency energy of a downsampled luma
 *    crop, normalized by local contrast. Screens re-photographed through a
 *    camera alias into abnormally high energy (moiré / pixel grid); blurred
 *    prints have abnormally low energy. Values inside the natural band score
 *    1.0 and degrade toward a floor of 0.3 outside it, so texture alone can
 *    never fail a real user.
 *
 * Cues that could not be measured (e.g. no turn challenge in the session, so
 * no yaw range) are dropped and the remaining weights renormalized. With no
 * evidence at all the detector returns a neutral 0.5.
 */
internal class HeuristicAntiSpoofDetector : AntiSpoofDetector {

    companion object {
        private const val MAX_SAMPLES = 600
        private const val MAX_TEXTURE_SAMPLES = 60

        private const val MIN_SAMPLES_FOR_PARALLAX = 12
        private const val MIN_YAW_RANGE_DEG = 15f
        private const val EXPECTED_NOSE_SLOPE = 0.20

        private const val MOTION_FULL_SCORE = 0.0015
        private const val MIN_MOTION_PAIRS = 10
        private const val MAX_MOTION_GAP_MS = 300L

        private const val HF_LOW = 0.06
        private const val HF_HIGH = 0.55
        private const val TEXTURE_FLOOR = 0.3

        private const val W_PARALLAX = 0.55
        private const val W_MOTION = 0.25
        private const val W_TEXTURE = 0.20
    }

    private class Sample(
        val t: Long,
        val yawDeg: Float,
        /** Nose x offset from the cheek midpoint, normalized by face width. */
        val relNoseX: Double,
        val normNoseX: Double,
        val normNoseY: Double,
    )

    private val samples = ArrayList<Sample>()
    private val textureStats = ArrayList<Double>()

    override fun onObservation(obs: FaceObservation, lumaCrop: LumaCrop?) {
        val box = obs.boundingBox
        if (obs.faceCount == 1 && box != null && box.width() > 0) {
            val nose = obs.landmarks[FaceLandmark.NOSE_BASE]
            if (nose != null) {
                val leftCheek = obs.landmarks[FaceLandmark.LEFT_CHEEK]
                val rightCheek = obs.landmarks[FaceLandmark.RIGHT_CHEEK]
                val refX = if (leftCheek != null && rightCheek != null) {
                    (leftCheek.x + rightCheek.x) / 2f
                } else {
                    box.exactCenterX()
                }
                samples += Sample(
                    t = obs.timestampMs,
                    yawDeg = obs.eulerY,
                    relNoseX = ((nose.x - refX) / box.width()).toDouble(),
                    normNoseX = nose.x.toDouble() / obs.frameWidth,
                    normNoseY = nose.y.toDouble() / obs.frameHeight,
                )
                if (samples.size > MAX_SAMPLES) samples.removeAt(0)
            }
        }
        if (lumaCrop != null) {
            textureStats += highFrequencyRatio(lumaCrop)
            if (textureStats.size > MAX_TEXTURE_SAMPLES) textureStats.removeAt(0)
        }
    }

    override fun computeScore(): Double {
        val parallax = parallaxScore()
        val motion = microMotionScore()
        val texture = textureScore()
        var total = 0.0
        var weight = 0.0
        if (parallax != null) {
            total += W_PARALLAX * parallax
            weight += W_PARALLAX
        }
        if (motion != null) {
            total += W_MOTION * motion
            weight += W_MOTION
        }
        if (texture != null) {
            total += W_TEXTURE * texture
            weight += W_TEXTURE
        }
        if (weight <= 0.0) return 0.5 // No evidence either way.
        return (total / weight).coerceIn(0.0, 1.0)
    }

    override fun reset() {
        samples.clear()
        textureStats.clear()
    }

    // ------------------------------------------------------------------ cues

    private fun parallaxScore(): Double? {
        if (samples.size < MIN_SAMPLES_FOR_PARALLAX) return null
        var minYaw = Float.MAX_VALUE
        var maxYaw = -Float.MAX_VALUE
        for (s in samples) {
            minYaw = min(minYaw, s.yawDeg)
            maxYaw = max(maxYaw, s.yawDeg)
        }
        if (maxYaw - minYaw < MIN_YAW_RANGE_DEG) return null
        val xs = DoubleArray(samples.size) { sin(samples[it].yawDeg * PI / 180.0) }
        val ys = DoubleArray(samples.size) { samples[it].relNoseX }
        val slope = fitSlope(xs, ys)
        return (abs(slope) / EXPECTED_NOSE_SLOPE).coerceIn(0.0, 1.0)
    }

    private fun microMotionScore(): Double? {
        val displacements = ArrayList<Double>()
        for (i in 1 until samples.size) {
            val a = samples[i - 1]
            val b = samples[i]
            val dt = b.t - a.t
            if (dt in 1..MAX_MOTION_GAP_MS) {
                displacements += hypot(b.normNoseX - a.normNoseX, b.normNoseY - a.normNoseY)
            }
        }
        if (displacements.size < MIN_MOTION_PAIRS) return null
        displacements.sort()
        val median = displacements[displacements.size / 2]
        return (median / MOTION_FULL_SCORE).coerceIn(0.0, 1.0)
    }

    private fun textureScore(): Double? {
        if (textureStats.size < 5) return null
        val sorted = textureStats.sorted()
        val hf = sorted[sorted.size / 2]
        return when {
            hf < HF_LOW -> TEXTURE_FLOOR + (1.0 - TEXTURE_FLOOR) * (hf / HF_LOW)
            hf > HF_HIGH -> (1.0 - (hf - HF_HIGH) / HF_HIGH).coerceIn(TEXTURE_FLOOR, 1.0)
            else -> 1.0
        }
    }

    // --------------------------------------------------------------- helpers

    /** Least-squares slope of ys against xs. */
    private fun fitSlope(xs: DoubleArray, ys: DoubleArray): Double {
        val n = xs.size
        if (n < 2) return 0.0
        val meanX = xs.average()
        val meanY = ys.average()
        var num = 0.0
        var den = 0.0
        for (i in 0 until n) {
            val dx = xs[i] - meanX
            num += dx * (ys[i] - meanY)
            den += dx * dx
        }
        return if (den < 1e-9) 0.0 else num / den
    }

    /** Mean |Laplacian| of the crop, normalized by its contrast (std dev). */
    private fun highFrequencyRatio(crop: LumaCrop): Double {
        val w = crop.width
        val h = crop.height
        val d = crop.data
        if (w < 3 || h < 3) return 0.0
        val n = w * h
        var sum = 0.0
        var sumSq = 0.0
        for (i in 0 until n) {
            val v = (d[i].toInt() and 0xFF).toDouble()
            sum += v
            sumSq += v * v
        }
        val mean = sum / n
        val std = sqrt((sumSq / n - mean * mean).coerceAtLeast(0.0))
        var lap = 0.0
        var count = 0
        for (y in 1 until h - 1) {
            for (x in 1 until w - 1) {
                val c = d[y * w + x].toInt() and 0xFF
                val l = d[y * w + x - 1].toInt() and 0xFF
                val r = d[y * w + x + 1].toInt() and 0xFF
                val u = d[(y - 1) * w + x].toInt() and 0xFF
                val b = d[(y + 1) * w + x].toInt() and 0xFF
                lap += abs(4 * c - l - r - u - b).toDouble()
                count++
            }
        }
        val meanLap = if (count == 0) 0.0 else lap / count / 4.0
        return meanLap / (std + 1.0)
    }
}
