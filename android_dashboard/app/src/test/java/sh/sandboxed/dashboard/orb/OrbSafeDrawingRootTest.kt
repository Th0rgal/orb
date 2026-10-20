package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertLeftPositionInRootIsEqualTo
import androidx.compose.ui.test.assertTopPositionInRootIsEqualTo
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Screens drawn inside OrbSafeDrawingRoot are offset by the safe-drawing insets
 * (here a tall emulated cutout on the top edge and a gesture bar at the bottom),
 * and nested inset modifiers do not double-pad because the root consumes them.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w400dp-h800dp")
class OrbSafeDrawingRootTest {
    @get:Rule val rule = createComposeRule()

    private val cutoutInsets = WindowInsets(left = 0.dp, top = 52.dp, right = 0.dp, bottom = 24.dp)

    @Test
    fun contentStartsBelowCutoutAndAboveGestureBar() {
        rule.setContent {
            OrbSafeDrawingRoot(insets = cutoutInsets) {
                Box(Modifier.fillMaxSize().testTag("screen"))
            }
        }
        rule.onNodeWithTag("screen").assertTopPositionInRootIsEqualTo(52.dp)
        rule.onNodeWithTag("screen").assertLeftPositionInRootIsEqualTo(0.dp)
        val b = rule.onNodeWithTag("screen").getBoundsInRoot()
        assertEquals(800f - 52f - 24f, (b.bottom - b.top).value, 0.5f)
    }

    @Test
    fun setupScreenIsInsideTheSafeRoot() {
        // The first-run screen is rendered through the same root as the main layout.
        rule.setContent {
            OrbSafeDrawingRoot(insets = cutoutInsets) {
                Box(Modifier.testTag("setup"))
            }
        }
        rule.onNodeWithTag("setup").assertTopPositionInRootIsEqualTo(52.dp)
    }

    @Test
    fun nestedInsetModifiersAreConsumedByTheRoot() {
        rule.setContent {
            OrbSafeDrawingRoot(insets = cutoutInsets) {
                Box(Modifier.statusBarsPadding().imePadding().testTag("inner"))
            }
        }
        rule.onNodeWithTag("inner").assertTopPositionInRootIsEqualTo(52.dp)
    }
}
