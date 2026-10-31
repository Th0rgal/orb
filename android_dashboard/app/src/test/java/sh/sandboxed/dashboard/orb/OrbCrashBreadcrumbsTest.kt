package sh.sandboxed.dashboard.orb

import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class OrbCrashBreadcrumbsTest {
    @Test
    fun crashDrainRecordsOnlyStructuralMetadata() {
        OrbLog.logcatEnabled = false
        OrbLog.clear()
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        OrbCrashBreadcrumbs.enterConversation("mission-structural-id", 3)
        OrbCrashBreadcrumbs.recordCrashForTest(context, IllegalStateException("secret prompt text"))
        OrbCrashBreadcrumbs.drainPendingForTest(context)
        val entry = OrbLog.latest()?.message.orEmpty()
        assertTrue(entry.contains("missionId=mission-structural-id"))
        assertFalse(entry.contains("secret prompt text"))
    }
}
