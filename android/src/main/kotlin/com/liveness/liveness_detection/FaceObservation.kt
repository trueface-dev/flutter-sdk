package com.liveness.liveness_detection

import android.graphics.PointF
import android.graphics.Rect

/**
 * One analyzed camera frame, expressed in the coordinates of the upright,
 * rotation-corrected (and, importantly, UN-mirrored) analysis image that
 * ML Kit saw.
 *
 * When [faceCount] != 1 only the frame-level fields are meaningful.
 */
class FaceObservation(
    val timestampMs: Long,
    val frameWidth: Int,
    val frameHeight: Int,
    val faceCount: Int,
    /** Mean luminance (0-255) sampled from the central region of the frame. */
    val meanLuma: Double,
    val boundingBox: Rect? = null,
    val eulerX: Float = 0f,
    val eulerY: Float = 0f,
    val eulerZ: Float = 0f,
    val leftEyeOpenProb: Float? = null,
    val rightEyeOpenProb: Float? = null,
    val smileProb: Float? = null,
    /** ML Kit landmark positions keyed by [com.google.mlkit.vision.face.FaceLandmark] type. */
    val landmarks: Map<Int, PointF> = emptyMap(),
)

/** A small grayscale crop of the central face region used for texture analysis. */
class LumaCrop(val width: Int, val height: Int, val data: ByteArray)
