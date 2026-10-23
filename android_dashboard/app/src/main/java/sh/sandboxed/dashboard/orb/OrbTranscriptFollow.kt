package sh.sandboxed.dashboard.orb

/**
 * Whether the transcript follows the latest message, decided by the reader's own
 * scrolling only (desktop pinnedScroll, iOS OrbTranscriptScroller): a drag
 * unpins at once; the list coming to rest at its end pins again. New content,
 * a growing streaming answer or a narration fold never changes it, so a reader
 * who scrolled up stays where they are while the agent writes below.
 */
class OrbTranscriptFollow {
    var pinned: Boolean = true
        private set

    /** The reader put a finger on the list. */
    fun onDragStart() { pinned = false }

    /** A drag or fling ended, or the list settled; [atEnd] is "cannot scroll further down". */
    fun onSettled(atEnd: Boolean) { if (atEnd) pinned = true }

    /** Jump to latest, or a send by the reader. */
    fun pin() { pinned = true }

    /** Scroll to the bottom on new content: always before the first anchoring, then only while pinned. */
    fun shouldFollow(anchoredInitial: Boolean): Boolean = !anchoredInitial || pinned
}
