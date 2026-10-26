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
    var dragging: Boolean = false
        private set
    var layoutEpoch: Int = 1
        private set
    var lastCorrectedEpoch: Int = 0
        private set
    var correctionsInEpoch: Int = 0
        private set
    var parityDigest: Long = 0L
        private set
    var parityAdmitted: Boolean = true
        private set

    /** The reader put a finger on the list. */
    fun onDragStart() {
        dragging = true
        pinned = false
    }

    /** A drag or fling ended, or the list settled; [atEnd] is "cannot scroll further down". */
    fun onSettled(atEnd: Boolean) {
        dragging = false
        if (atEnd) pinned = true
    }

    /** Jump to latest, or a send by the reader. */
    fun pin() {
        dragging = false
        pinned = true
    }

    /** Advance the layout epoch when transcript turns or streaming blocks mutate. */
    fun advanceLayoutEpoch() {
        layoutEpoch += 1
        correctionsInEpoch = 0
    }

    /** Scroll to the bottom on new content: always before the first anchoring, then only while pinned. */
    fun shouldFollow(anchoredInitial: Boolean): Boolean = !anchoredInitial || pinned

    /**
     * Evaluate `OrbKernel.scrollEpochStep` (`scroll_correction_at_most_once_per_epoch`) in the
     * current layout epoch so at most one programmatic scroll correction fires per epoch.
     */
    fun shouldCorrectInEpoch(targetTopPx: Int, currentTopPx: Int): Boolean {
        if (OrbKernel.nativeLoaded) {
            val verdict = OrbKernel.scrollEpochStep(
                layoutEpoch = layoutEpoch,
                lastCorrectedEpoch = lastCorrectedEpoch,
                correctionsInEpoch = correctionsInEpoch,
                isPinnedToBottom = pinned,
                userIsDragging = dragging,
                targetScrollTopPx = targetTopPx,
                currentScrollTopPx = currentTopPx
            )
            correctionsInEpoch = verdict.nextCorrectionsInEpoch
            if (verdict.applyCorrection) {
                lastCorrectedEpoch = layoutEpoch
            }
            return verdict.applyCorrection
        }
        val newEpoch = layoutEpoch > lastCorrectedEpoch
        val effCorrections = if (newEpoch) 0 else correctionsInEpoch
        if (!pinned || dragging || targetTopPx == currentTopPx) {
            correctionsInEpoch = effCorrections
            return false
        }
        if (effCorrections > 0) {
            correctionsInEpoch = effCorrections
            return false
        }
        correctionsInEpoch = 1
        lastCorrectedEpoch = layoutEpoch
        return true
    }

    /**
     * Evaluate `OrbKernel.clientParityStep` (`client_projection_bitwise_parity_across_ios_android_wasm`)
     * for the Android projection (`clientTarget = 2`).
     */
    fun verifyClientParity(
        transcriptSeq: Int,
        markdownBlocksCount: Int,
        sendQueueDepth: Int,
        wireSchemaId: Int = 1
    ): Long {
        if (OrbKernel.nativeLoaded) {
            val verdict = OrbKernel.clientParityStep(
                clientTarget = 2,
                wireSchemaId = wireSchemaId,
                transcriptSeq = transcriptSeq,
                markdownBlocksCount = markdownBlocksCount,
                sendQueueDepth = sendQueueDepth,
                scrollCorrectedInEpoch = correctionsInEpoch
            )
            parityAdmitted = verdict.parityAdmitted
            parityDigest = verdict.digest32
            return parityDigest
        }
        parityAdmitted = wireSchemaId in 1..2
        parityDigest = ((transcriptSeq.toLong() and 0xFFFF_FFFFL) xor
            ((markdownBlocksCount.toLong() shl 16) and 0xFFFF_FFFFL) xor
            ((sendQueueDepth.toLong() shl 24) and 0xFFFF_FFFFL)) and 0xFFFF_FFFFL
        return parityDigest
    }
}
