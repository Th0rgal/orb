package sh.sandboxed.dashboard

import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class OrbPolishTest {
    @Test fun inboxPreviewAndReplyKeepControlsVisible() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        // A fixture session must never overwrite the real app's account or drafts.
        check(context.packageName.endsWith(".preview"))
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        context.startActivity(Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            .putExtra("orb_base_url", "http://127.0.0.1:18766")
            .putExtra("orb_open_inbox", true))
        assertTrue(device.wait(Until.hasObject(By.text("Needs you")), 20_000))
        fun capture(name: String) {
            device.waitForIdle()
            assertTrue(device.takeScreenshot(File(context.getExternalFilesDir(null), "$name.png")))
        }
        capture("polished-inbox")
        val peek = device.wait(Until.findObject(By.text("Peek")), 5_000)
        assertNotNull(peek)
        peek.click()
        assertTrue(device.wait(Until.hasObject(By.text("Restore the interrupted conversation safely.")), 10_000))
        assertTrue(device.wait(Until.hasObject(By.text("Unresolved")), 5_000))
        assertTrue(device.wait(Until.hasObject(By.text("To decide")), 5_000))
        capture("polished-inbox-preview")
        device.findObject(By.text("Reply")).click()
        val input = device.wait(Until.findObject(By.clazz("android.widget.EditText")), 5_000)
        assertNotNull(input)
        input.click()
        input.text = "Unsent layout check"
        assertTrue(device.wait(Until.hasObject(By.text("Unsent layout check")), 5_000))
        capture("polished-inbox-keyboard")
    }
    @Test fun conversationComposerAndModelPicker() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        check(context.packageName.endsWith(".preview"))
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        context.startActivity(Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            .putExtra("orb_base_url", "http://127.0.0.1:18766")
            .putExtra("orb_open_project", "orb-test")
            .putExtra("orb_open_mission", "existing"))
        val input = device.wait(Until.findObject(By.clazz("android.widget.EditText")), 20_000)
        assertNotNull(input)
        device.waitForIdle()
        assertTrue(device.takeScreenshot(File(context.getExternalFilesDir(null), "polished-composer.png")))
        input.click()
        input.text = "Unsent composer check"
        assertTrue(device.wait(Until.hasObject(By.text("Unsent composer check")), 5_000))
        device.waitForIdle()
        assertTrue(device.takeScreenshot(File(context.getExternalFilesDir(null), "polished-composer-keyboard.png")))
        device.findObject(By.text(java.util.regex.Pattern.compile(".*claude.*", java.util.regex.Pattern.CASE_INSENSITIVE))).click()
        assertTrue(device.wait(Until.hasObject(By.text("Agent Configuration")), 5_000))
        device.waitForIdle()
        assertTrue(device.takeScreenshot(File(context.getExternalFilesDir(null), "polished-model-picker.png")))
        device.findObject(By.text("Done")).click()
        assertTrue(device.wait(Until.hasObject(By.text("Unsent composer check")), 5_000))
    }

}
