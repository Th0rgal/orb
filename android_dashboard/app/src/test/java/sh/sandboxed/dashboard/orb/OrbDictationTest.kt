package sh.sandboxed.dashboard.orb

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class OrbDictationTest {
    private class FakeAudioSource(
        override val bufferSize: Int = 64,
        private val onRead: (callIndex: Int, buffer: ByteArray, stopped: Boolean) -> Int,
    ) : OrbSparkRecorder.AudioSource {
        val started = AtomicBoolean(false)
        val stopped = AtomicBoolean(false)
        val released = AtomicBoolean(false)
        private val calls = AtomicInteger(0)

        override fun startRecording() {
            started.set(true)
        }

        override fun read(buffer: ByteArray, offset: Int, size: Int): Int {
            return onRead(calls.incrementAndGet(), buffer, stopped.get())
        }

        override fun stop() {
            stopped.set(true)
        }

        override fun release() {
            released.set(true)
        }
    }

    private fun extractWavPcm(wav: ByteArray): ByteArray {
        assertTrue("WAV must contain 44-byte RIFF header", wav.size >= 44)
        assertEquals("RIFF", wav.copyOfRange(0, 4).decodeToString())
        assertEquals("WAVE", wav.copyOfRange(8, 12).decodeToString())
        assertEquals("data", wav.copyOfRange(36, 40).decodeToString())
        val dataLen = ByteBuffer.wrap(wav, 40, 4).order(ByteOrder.LITTLE_ENDIAN).int
        assertEquals(wav.size - 44, dataLen)
        return wav.copyOfRange(44, wav.size)
    }

    @Test
    fun rapidCancelAndRestartNeverLeaksGen1BytesIntoGen2AndIgnoresLateGen1Callbacks() = runBlocking {
        val gen1FirstChunkWritten = CountDownLatch(1)
        val gen1EnteredSecondRead = CountDownLatch(1)
        val releaseGen1StuckRead = CountDownLatch(1)
        val gen1Exited = CountDownLatch(1)

        val gen2ChunksDone = CountDownLatch(1)
        val gen2StopGate = CountDownLatch(1)

        val source1 = FakeAudioSource(bufferSize = 16) { call, buf, _ ->
            when (call) {
                1 -> {
                    repeat(8) { buf[it] = 0x11 }
                    8
                }
                2 -> {
                    gen1FirstChunkWritten.countDown()
                    gen1EnteredSecondRead.countDown()
                    releaseGen1StuckRead.await(5, TimeUnit.SECONDS)
                    repeat(8) { buf[it] = 0x1F }
                    gen1Exited.countDown()
                    8
                }
                else -> -1
            }
        }

        val source2 = FakeAudioSource(bufferSize = 16) { call, buf, stopped ->
            when {
                stopped -> -1
                call == 1 -> {
                    repeat(6) { buf[it] = 0x22 }
                    6
                }
                call == 2 -> {
                    repeat(6) { buf[it] = 0x23 }
                    6
                }
                else -> {
                    gen2ChunksDone.countDown()
                    gen2StopGate.await(5, TimeUnit.SECONDS)
                    -1
                }
            }
        }

        val created = AtomicInteger(0)
        val recorder = OrbSparkRecorder(
            sourceFactory = {
                when (created.incrementAndGet()) {
                    1 -> source1
                    2 -> source2
                    else -> null
                }
            },
            joinTimeoutMs = 25L,
        )

        assertTrue(recorder.start())
        val gen1 = recorder.currentGeneration
        assertEquals(1L, gen1)
        assertTrue(gen1FirstChunkWritten.await(2, TimeUnit.SECONDS))
        assertTrue(gen1EnteredSecondRead.await(2, TimeUnit.SECONDS))

        val transcribeGate1 = CompletableDeferred<String>()
        val publishedCallbacks = mutableListOf<Pair<Long, String?>>()
        val staleTranscription = async {
            recorder.transcribeSession(
                generation = gen1,
                wav = ByteArray(60),
                transcribe = { transcribeGate1.await() },
                onResult = { text -> publishedCallbacks += gen1 to text },
            )
        }

        recorder.cancel()
        assertTrue(source1.stopped.get())
        assertFalse(recorder.isCurrentGeneration(gen1))

        assertTrue(recorder.start())
        val gen2 = recorder.currentGeneration
        assertTrue(gen2 > gen1)
        assertTrue(recorder.isCurrentGeneration(gen2))

        releaseGen1StuckRead.countDown()
        assertTrue(gen1Exited.await(2, TimeUnit.SECONDS))
        assertTrue(gen2ChunksDone.await(2, TimeUnit.SECONDS))

        transcribeGate1.complete("stale transcript from gen 1")
        assertFalse(staleTranscription.await())
        assertFalse(recorder.runIfCurrent(gen1) { publishedCallbacks += gen1 to "late state update" })
        assertTrue(publishedCallbacks.isEmpty())

        gen2StopGate.countDown()
        val stoppedSession = recorder.stopSession()
        assertNotNull(stoppedSession)
        val (stoppedGen, wav2) = stoppedSession!!
        assertEquals(gen2, stoppedGen)

        val pcm2 = extractWavPcm(wav2)
        val expectedPcm2 = ByteArray(12) { idx -> if (idx < 6) 0x22 else 0x23 }
        assertArrayEquals(expectedPcm2, pcm2)
        assertTrue(pcm2.none { it == 0x11.toByte() || it == 0x1F.toByte() })

        val acceptedGen2 = recorder.transcribeSession(
            generation = stoppedGen,
            wav = wav2,
            transcribe = { "clean transcript from gen 2" },
            onResult = { text -> publishedCallbacks += stoppedGen to text },
        )
        assertTrue(acceptedGen2)
        assertEquals(listOf(gen2 to "clean transcript from gen 2"), publishedCallbacks)
        assertTrue(source2.stopped.get())
        assertTrue(source2.released.get())
    }

    @Test
    fun stopJoinsWorkerBeforeFinalizingBytesAndReleasesAudioSource() {
        val firstChunkWritten = CountDownLatch(1)
        val enteredSecondRead = CountDownLatch(1)
        val workerFinishedAfterStop = CountDownLatch(1)
        val source = FakeAudioSource(bufferSize = 16) { call, buf, _ ->
            when (call) {
                1 -> {
                    repeat(4) { idx -> buf[idx] = (idx + 1).toByte() }
                    4
                }
                2 -> {
                    firstChunkWritten.countDown()
                    enteredSecondRead.countDown()
                    Thread.sleep(40)
                    workerFinishedAfterStop.countDown()
                    -1
                }
                else -> -1
            }
        }

        val recorder = OrbSparkRecorder(sourceFactory = { source }, joinTimeoutMs = 1_000L)
        assertTrue(recorder.start())
        assertTrue(firstChunkWritten.await(2, TimeUnit.SECONDS))
        assertTrue(enteredSecondRead.await(2, TimeUnit.SECONDS))

        val wav = recorder.stop()
        assertTrue(workerFinishedAfterStop.await(0, TimeUnit.MILLISECONDS))
        assertNotNull(wav)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), extractWavPcm(wav!!))
        assertTrue(source.stopped.get())
        assertTrue(source.released.get())
    }

    @Test
    fun directRestartWithoutExplicitCancelIsolatesBuffersAndAdvancesGeneration() {
        val gen1EnteredRead = CountDownLatch(1)
        val releaseGen1Read = CountDownLatch(1)
        val gen1Exited = CountDownLatch(1)
        val gen2Done = CountDownLatch(1)
        val gen2Hold = CountDownLatch(1)

        val source1 = FakeAudioSource(bufferSize = 16) { call, buf, _ ->
            when (call) {
                1 -> {
                    gen1EnteredRead.countDown()
                    releaseGen1Read.await(2, TimeUnit.SECONDS)
                    repeat(8) { buf[it] = 0x5A }
                    gen1Exited.countDown()
                    8
                }
                else -> -1
            }
        }
        val source2 = FakeAudioSource(bufferSize = 16) { call, buf, stopped ->
            when {
                stopped -> -1
                call == 1 -> {
                    repeat(5) { buf[it] = 0x33 }
                    5
                }
                else -> {
                    gen2Done.countDown()
                    gen2Hold.await(2, TimeUnit.SECONDS)
                    -1
                }
            }
        }

        val count = AtomicInteger(0)
        val recorder = OrbSparkRecorder(
            sourceFactory = { if (count.incrementAndGet() == 1) source1 else source2 },
            joinTimeoutMs = 20L,
        )

        assertTrue(recorder.start())
        val gen1 = recorder.currentGeneration
        assertTrue(gen1EnteredRead.await(2, TimeUnit.SECONDS))

        assertTrue(recorder.start())
        val gen2 = recorder.currentGeneration
        assertEquals(gen1 + 1, gen2)
        assertFalse(recorder.isCurrentGeneration(gen1))

        releaseGen1Read.countDown()
        assertTrue(gen1Exited.await(2, TimeUnit.SECONDS))
        assertTrue(gen2Done.await(2, TimeUnit.SECONDS))
        gen2Hold.countDown()

        val (stoppedGen, wav2) = recorder.stopSession()!!
        assertEquals(gen2, stoppedGen)
        assertArrayEquals(ByteArray(5) { 0x33 }, extractWavPcm(wav2))
    }

    private fun overlappingTranscriptionOutcomeIsFenced(staleOutcome: () -> String) = runBlocking {
        val reads = List(2) { CountDownLatch(1) }
        val sources = List(2) { index ->
            FakeAudioSource(bufferSize = 16) { call, buf, _ ->
                if (call == 1) {
                    buf[0] = (index + 1).toByte()
                    1
                } else {
                    reads[index].countDown()
                    -1
                }
            }
        }
        val sourceIndex = AtomicInteger(0)
        val recorder = OrbSparkRecorder(sourceFactory = { sources[sourceIndex.getAndIncrement()] })
        val gen1Entered = CompletableDeferred<Unit>()
        val releaseGen1 = CompletableDeferred<Unit>()
        val gen2Entered = CompletableDeferred<Unit>()
        val releaseGen2 = CompletableDeferred<Unit>()
        val transcribeCalls = AtomicInteger(0)
        var inputText = "draft"
        var phase = OrbAndroidDictationPhase.Idle
        var fallbacks = 0
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        val coordinator = OrbSparkDictationSessionCoordinator(
            recorder = recorder,
            transcribeWav = {
                if (transcribeCalls.incrementAndGet() == 1) {
                    gen1Entered.complete(Unit)
                    kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) {
                        releaseGen1.await()
                        staleOutcome()
                    }
                } else {
                    gen2Entered.complete(Unit)
                    releaseGen2.await()
                    "fresh transcript"
                }
            },
            onPhaseChange = { phase = it },
            onAppendTranscript = { inputText += " $it" },
            onFallbackSystemSpeech = { fallbacks++; phase = OrbAndroidDictationPhase.Listening },
        )
        try {
            assertTrue(coordinator.startRecording())
            val gen1 = recorder.currentGeneration
            assertTrue(reads[0].await(2, TimeUnit.SECONDS))
            coordinator.finishRecording(scope)
            gen1Entered.await()
            val staleJob = coordinator.activeTranscribeJob!!
            assertEquals(OrbAndroidDictationPhase.Transcribing, phase)
            coordinator.cancel()
            assertTrue(staleJob.isCancelled)
            assertEquals(OrbAndroidDictationPhase.Idle, phase)
            assertFalse(recorder.isCurrentGeneration(gen1))

            assertTrue(coordinator.startRecording())
            assertTrue(reads[1].await(2, TimeUnit.SECONDS))
            coordinator.finishRecording(scope)
            gen2Entered.await()
            val freshJob = coordinator.activeTranscribeJob!!
            assertEquals(OrbAndroidDictationPhase.Transcribing, phase)

            releaseGen1.complete(Unit)
            staleJob.join()
            assertEquals("draft", inputText)
            assertEquals(OrbAndroidDictationPhase.Transcribing, phase)
            assertEquals(0, fallbacks)
            assertEquals(freshJob, coordinator.activeTranscribeJob)

            releaseGen2.complete(Unit)
            freshJob.join()
            assertEquals("draft fresh transcript", inputText)
            assertEquals(OrbAndroidDictationPhase.Idle, phase)
            assertEquals(0, fallbacks)
        } finally {
            releaseGen1.complete(Unit)
            releaseGen2.complete(Unit)
            coordinator.cancel()
            scope.cancel()
        }
    }

    @Test
    fun cancelledGen1SuccessCannotOverwriteGen2Transcribing() =
        overlappingTranscriptionOutcomeIsFenced { "stale transcript" }

    @Test
    fun cancelledGen1FailureCannotFallbackDuringGen2Transcribing() =
        overlappingTranscriptionOutcomeIsFenced { throw java.io.IOException("stale failure") }

    @Test
    fun cancelledGen1EmptyCannotFallbackDuringGen2Transcribing() =
        overlappingTranscriptionOutcomeIsFenced { "" }
}
