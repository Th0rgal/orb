package sh.sandboxed.dashboard.orb

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OrbTranscriptFollowTest {
    @Test fun followsUntilTheReaderDragsAway() {
        val f = OrbTranscriptFollow()
        assertTrue(f.shouldFollow(anchoredInitial = true))
        f.onDragStart()
        assertFalse(f.shouldFollow(anchoredInitial = true))
    }

    @Test fun streamingBelowNeverRepinsAReaderInTheMiddle() {
        val f = OrbTranscriptFollow()
        f.onDragStart(); f.onSettled(atEnd = false)
        // Content keeps arriving: nothing but the reader's scrolling changes the state.
        repeat(50) { assertFalse(f.shouldFollow(anchoredInitial = true)) }
    }

    @Test fun settlingAtTheEndPinsAgain() {
        val f = OrbTranscriptFollow()
        f.onDragStart(); f.onSettled(atEnd = true)
        assertTrue(f.pinned)
    }

    @Test fun jumpToLatestPins() {
        val f = OrbTranscriptFollow()
        f.onDragStart(); f.pin()
        assertTrue(f.pinned)
    }

    @Test fun firstAnchoringAlwaysLandsAtTheBottom() {
        val f = OrbTranscriptFollow()
        f.onDragStart()
        assertTrue(f.shouldFollow(anchoredInitial = false))
    }
}
