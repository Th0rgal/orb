package sh.sandboxed.dashboard.orb

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Cover-screen geometry for foldable external displays (such as the Motorola Razr 60 Ultra's
 * 480dp x 565dp full-bleed cover screen with twin camera lenses in the bottom-right corner).
 */
@Immutable
data class OrbCoverScreenState(
    val isCoverScreen: Boolean = false,
    val cameraSafeEndPadding: Dp = 0.dp,
    val imeVisible: Boolean = false
) {
    /** End padding for bottom-anchored controls so they tuck left of twin cover cameras. */
    fun bottomBarEndPadding(defaultEnd: Dp = 0.dp): Dp =
        if (isCoverScreen && !imeVisible) maxOf(defaultEnd, cameraSafeEndPadding) else defaultEnd
}

val LocalOrbCoverScreen = compositionLocalOf { OrbCoverScreenState() }
