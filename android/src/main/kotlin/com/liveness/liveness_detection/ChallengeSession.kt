package com.liveness.liveness_detection

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import kotlin.math.abs

/**
 * The gating + challenge state machine described in doc/NATIVE_CONTRACT.md.
 *
 * All methods must be called on the main thread; all listener callbacks are
 * delivered on the main thread.
 */
class ChallengeSession(
    private val challenges: List<String>,
    private val challengeTimeoutMs: Long,
    private val listener: Listener,
) {

    interface Listener {
        /** An `onEvent` payload (event map) ready to be sent over the channel. */
        fun onSessionEvent(event: Map<String, Any>)

        /** Every challenge was satisfied; proceed to anti-spoof + capture. */
        fun onChallengesPassed(completed: List<String>)

        /** Terminal failure with a contract `failureReason` wire value. */
        fun onSessionFailed(reason: String, completed: List<String>)
    }

    companion object {
        // ------------------------------------------------ gating thresholds
        private const val MIN_FACE_WIDTH_RATIO = 0.25
        private const val MAX_FACE_WIDTH_RATIO = 0.60
        private const val CENTER_TOLERANCE_X = 0.18
        private const val CENTER_TOLERANCE_Y = 0.22
        private const val MIN_MEAN_LUMA = 60.0
        private const val FRONTAL_MAX_ANGLE_DEG = 12f

        /** Consecutive well-gated frames required before a challenge starts. */
        private const val GATE_OK_STREAK = 3

        // --------------------------------------------- challenge thresholds
        private const val EYE_CLOSED_PROB = 0.35f
        private const val EYE_OPEN_PROB = 0.7f
        private const val SMILE_PROB = 0.7f
        private const val TURN_ANGLE_DEG = 25f
        private const val TURN_RETURN_ANGLE_DEG = 12f
        private const val NOD_DOWN_ANGLE_DEG = -15f
        private const val NOD_RETURN_ANGLE_DEG = -5f

        /**
         * Maps ML Kit's `headEulerAngleY` sign onto "the USER's left".
         *
         * ML Kit reports yaw in the coordinates of the upright, UN-mirrored
         * analysis buffer (CameraX `ImageAnalysis` frames are never mirrored,
         * only the on-screen preview is): a positive eulerY means the face is
         * turned toward the RIGHT side of that image. A camera looking at the
         * user projects the user's LEFT side onto the image's RIGHT side, so
         * a turn to the user's left produces a POSITIVE eulerY. The same sign
         * holds for the front and back lens because the camera faces the
         * subject either way — the preview mirroring never reaches ML Kit.
         *
         * turnLeft  => eulerY * USER_LEFT_YAW_SIGN > +25° then back to center
         * turnRight => eulerY * USER_LEFT_YAW_SIGN < -25° then back to center
         */
        private const val USER_LEFT_YAW_SIGN = 1f

        private const val HINT_THROTTLE_MS = 1200L

        /** How long the face may stay lost mid-session before failing. */
        private const val FACE_LOST_FAIL_MS = 3000L
    }

    private enum class Phase { GATING, CHALLENGE, FINISHED }

    private val handler = Handler(Looper.getMainLooper())
    private val completed = mutableListOf<String>()
    private var index = 0
    private var phase = Phase.GATING
    private var faceVisible = false
    private var startedAnyChallenge = false
    private var gateOkStreak = 0
    private var lastHintCode: String? = null
    private var lastHintAt = 0L

    // Per-challenge two-step progress flags.
    private var blinkClosedSeen = false
    private var turnPeaked = false
    private var nodDownSeen = false

    // Pausable per-challenge timeout (paused while the face is lost).
    private var timeoutPending = false
    private var timeoutPostedAt = 0L
    private var timeoutRemainingMs = 0L

    private val timeoutRunnable = Runnable { fail("timeout") }
    private val faceLostRunnable = Runnable { fail("faceLost") }

    val completedChallenges: List<String>
        get() = completed.toList()

    /** Feed one analyzed frame. No-op once the session is finished. */
    fun onFrame(obs: FaceObservation) {
        if (phase == Phase.FINISHED) return
        when {
            obs.faceCount == 0 -> onNoFace()
            obs.faceCount > 1 -> {
                onFaceSeen()
                hint("multipleFaces")
                gateOkStreak = 0
            }
            else -> {
                onFaceSeen()
                onSingleFace(obs)
            }
        }
    }

    /** Stops timers and freezes the machine. Safe to call multiple times. */
    fun stop() {
        phase = Phase.FINISHED
        handler.removeCallbacks(timeoutRunnable)
        handler.removeCallbacks(faceLostRunnable)
    }

    // ------------------------------------------------------------ face gates

    private fun onNoFace() {
        if (faceVisible) {
            faceVisible = false
            listener.onSessionEvent(mapOf("type" to "faceLost"))
            pauseTimeout()
            // A blink/turn/nod interrupted by losing the face must restart.
            resetChallengeProgress()
            if (startedAnyChallenge) {
                handler.postDelayed(faceLostRunnable, FACE_LOST_FAIL_MS)
            }
        }
        gateOkStreak = 0
    }

    private fun onFaceSeen() {
        if (!faceVisible) {
            faceVisible = true
            handler.removeCallbacks(faceLostRunnable)
            listener.onSessionEvent(mapOf("type" to "faceDetected"))
            resumeTimeout()
        }
    }

    private fun onSingleFace(obs: FaceObservation) {
        when (phase) {
            Phase.GATING -> gate(obs)
            Phase.CHALLENGE -> checkChallenge(obs)
            Phase.FINISHED -> Unit
        }
    }

    private fun gate(obs: FaceObservation) {
        val failedHint = gateHint(obs)
        if (failedHint != null) {
            hint(failedHint)
            gateOkStreak = 0
            return
        }
        gateOkStreak++
        if (gateOkStreak >= GATE_OK_STREAK) startChallenge()
    }

    /** Returns the hint code of the first failing gate, or null if all pass. */
    private fun gateHint(obs: FaceObservation): String? {
        val box = obs.boundingBox ?: return "centerFace"
        val widthRatio = box.width().toDouble() / obs.frameWidth
        if (widthRatio < MIN_FACE_WIDTH_RATIO) return "moveCloser"
        if (widthRatio > MAX_FACE_WIDTH_RATIO) return "moveBack"
        val dx = abs(box.exactCenterX() - obs.frameWidth / 2.0) / obs.frameWidth
        val dy = abs(box.exactCenterY() - obs.frameHeight / 2.0) / obs.frameHeight
        if (dx > CENTER_TOLERANCE_X || dy > CENTER_TOLERANCE_Y) return "centerFace"
        if (obs.meanLuma < MIN_MEAN_LUMA) return "faceTooDark"
        if (abs(obs.eulerY) > FRONTAL_MAX_ANGLE_DEG || abs(obs.eulerX) > FRONTAL_MAX_ANGLE_DEG) {
            return "lookStraight"
        }
        return null
    }

    private fun hint(code: String) {
        val now = SystemClock.elapsedRealtime()
        if (code == lastHintCode && now - lastHintAt < HINT_THROTTLE_MS) return
        lastHintCode = code
        lastHintAt = now
        listener.onSessionEvent(mapOf("type" to "hint", "code" to code))
    }

    // ------------------------------------------------------------ challenges

    private fun startChallenge() {
        phase = Phase.CHALLENGE
        startedAnyChallenge = true
        resetChallengeProgress()
        listener.onSessionEvent(challengeEvent("challengeStarted"))
        startTimeout(challengeTimeoutMs)
    }

    private fun challengeEvent(type: String): Map<String, Any> = mapOf(
        "type" to type,
        "challenge" to challenges[index],
        "index" to index,
        "total" to challenges.size,
    )

    private fun checkChallenge(obs: FaceObservation) {
        val satisfied = when (challenges[index]) {
            "blink" -> checkBlink(obs)
            "smile" -> (obs.smileProb ?: 0f) > SMILE_PROB
            "turnLeft" -> checkTurn(obs, USER_LEFT_YAW_SIGN)
            "turnRight" -> checkTurn(obs, -USER_LEFT_YAW_SIGN)
            "nod" -> checkNod(obs)
            // Unknown wire names auto-pass rather than dead-locking a session.
            else -> true
        }
        if (satisfied) completeChallenge()
    }

    private fun checkBlink(obs: FaceObservation): Boolean {
        val left = obs.leftEyeOpenProb ?: return false
        val right = obs.rightEyeOpenProb ?: return false
        if (left < EYE_CLOSED_PROB && right < EYE_CLOSED_PROB) blinkClosedSeen = true
        return blinkClosedSeen && left > EYE_OPEN_PROB && right > EYE_OPEN_PROB
    }

    private fun checkTurn(obs: FaceObservation, userDirectionSign: Float): Boolean {
        if (obs.eulerY * userDirectionSign > TURN_ANGLE_DEG) turnPeaked = true
        return turnPeaked && abs(obs.eulerY) < TURN_RETURN_ANGLE_DEG
    }

    private fun checkNod(obs: FaceObservation): Boolean {
        if (obs.eulerX < NOD_DOWN_ANGLE_DEG) nodDownSeen = true
        return nodDownSeen && obs.eulerX > NOD_RETURN_ANGLE_DEG
    }

    private fun completeChallenge() {
        cancelTimeout()
        listener.onSessionEvent(challengeEvent("challengeCompleted"))
        completed += challenges[index]
        index++
        if (index >= challenges.size) {
            phase = Phase.FINISHED
            handler.removeCallbacks(faceLostRunnable)
            listener.onChallengesPassed(completed.toList())
        } else {
            phase = Phase.GATING
            gateOkStreak = 0
        }
    }

    private fun resetChallengeProgress() {
        blinkClosedSeen = false
        turnPeaked = false
        nodDownSeen = false
    }

    // --------------------------------------------------------------- timers

    private fun startTimeout(ms: Long) {
        handler.removeCallbacks(timeoutRunnable)
        handler.postDelayed(timeoutRunnable, ms)
        timeoutPending = true
        timeoutPostedAt = SystemClock.elapsedRealtime()
        timeoutRemainingMs = ms
    }

    private fun pauseTimeout() {
        if (!timeoutPending) return
        handler.removeCallbacks(timeoutRunnable)
        val elapsed = SystemClock.elapsedRealtime() - timeoutPostedAt
        timeoutRemainingMs = (timeoutRemainingMs - elapsed).coerceAtLeast(500L)
        timeoutPending = false
    }

    private fun resumeTimeout() {
        if (phase == Phase.CHALLENGE && !timeoutPending && timeoutRemainingMs > 0) {
            startTimeout(timeoutRemainingMs)
        }
    }

    private fun cancelTimeout() {
        handler.removeCallbacks(timeoutRunnable)
        timeoutPending = false
    }

    private fun fail(reason: String) {
        if (phase == Phase.FINISHED) return
        stop()
        listener.onSessionFailed(reason, completed.toList())
    }
}
