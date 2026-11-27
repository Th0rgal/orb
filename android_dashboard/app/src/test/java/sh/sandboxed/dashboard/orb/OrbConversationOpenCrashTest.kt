package sh.sandboxed.dashboard.orb

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Opening a mission or project page with seeded content must compose without crashing. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w400dp-h800dp")
class OrbConversationOpenCrashTest {
    @get:Rule val rule = createComposeRule()

    private val project = OrbRow("demo", mapOf("id" to "demo", "slug" to "demo", "name" to "Demo"))

    private val history = listOf(
        mapOf("role" to "user", "content" to "Please summarize the **build** status and show a table."),
        mapOf(
            "role" to "assistant",
            "content" to """
                # Build report

                Everything is *green*. Here is the snippet:

                ```kotlin
                fun main() {
                    println("hello")
                }
                ```

                | Module | Status | Time |
                |--------|:------:|-----:|
                | app    | ok     | 12s  |
                | core   | ok     | 4s   |

                - item one
                - item `two`
            """.trimIndent()
        )
    )

    private fun mission(status: String) = OrbRow(
        "m-1",
        mapOf(
            "id" to "m-1",
            "title" to "Test mission",
            "status" to status,
            "project" to "demo",
            "history" to history
        )
    )

    private fun openMission(status: String) {
        val core = OrbCore.getInstance(ApplicationProvider.getApplicationContext())
        val mission = mission(status)
        rule.setContent {
            OrbConversationPage(core = core, project = project, initialMission = mission, onBack = {})
        }
        rule.mainClock.advanceTimeBy(500)
        rule.waitForIdle()
    }

    @Test
    fun openCompletedMissionContentDoesNotCrash() = openMission("completed")

    @Test
    fun openActiveMissionContentDoesNotCrash() = openMission("active")

    @Test
    fun openProjectPageWithSubfolders() {
        val core = OrbCore.getInstance(ApplicationProvider.getApplicationContext())
        fun m(id: String, folder: String) = OrbRow(
            id,
            mapOf("id" to id, "title" to "Mission $id", "status" to "completed", "project" to "demo", "folder" to folder)
        )
        OrbReadCache.saveRowsMemoryOnly(
            "project_missions_demo",
            listOf(m("root-1", ""), m("alpha-1", "alpha"), m("beta-1", "alpha/beta"))
        )
        rule.setContent {
            OrbProjectPage(
                core = core,
                project = project,
                onBack = {},
                onOpenMission = {},
                onNewAgent = {},
                onOpenDocuments = {}
            )
        }
        rule.mainClock.advanceTimeBy(500)
        rule.waitForIdle()

        rule.onNodeWithText("Controller").assertDoesNotExist()
        rule.onNodeWithText("Steer").assertDoesNotExist()
        rule.onNodeWithText("alpha").assertIsDisplayed()
        rule.onNodeWithText("beta").assertIsDisplayed()

        rule.onNodeWithText("alpha").performClick()
        rule.mainClock.advanceTimeBy(500)
        rule.waitForIdle()
        rule.onNodeWithText("beta").assertDoesNotExist()
    }

    @Test
    fun openMissionWithRichEventsDoesNotCrash() {
        val core = OrbCore.getInstance(ApplicationProvider.getApplicationContext())
        val id = "m-rich"
        val bigMarkdown = buildString {
            var i = 0
            while (length < 45_000) {
                append("## Section $i\n\nParagraph with **bold**, *italic* and `code` number $i.\n\n")
                append("| a | b |\n|---|---|\n| $i | ${i * 2} |\n\n")
                i++
            }
        }
        check(bigMarkdown.length > 40_000)
        var seq = 0
        fun ev(type: String, extra: Map<String, Any?>): OrbRow {
            seq++
            return OrbRow(
                "ev-$seq",
                mapOf("id" to "ev-$seq", "mission_id" to id, "sequence" to seq, "event_type" to type) + extra
            )
        }
        val events = listOf(
            ev("user_message", mapOf("content" to "Render everything please.")),
            ev("thinking", mapOf("content" to "Thinking about **how** to render this.")),
            ev("tool_call", mapOf("data" to mapOf("name" to "bash", "tool_call_id" to "t1", "args" to mapOf("command" to "ls -la")))),
            ev("tool_result", mapOf("data" to mapOf("name" to "bash", "tool_call_id" to "t1", "result" to "foo.txt\nbar.txt"))),
            ev(
                "assistant_message",
                mapOf(
                    "content" to """
                        Here is the file: <file path="foo.txt" name="foo.txt"/>

                        $${'$'}E=mc^2$${'$'}

                        | Col A | Col B |
                        |-------|-------|
                        | 1     | 2     |

                        ```python
                        print("hi")
                        ```
                    """.trimIndent()
                )
            ),
            ev("assistant_message", mapOf("content" to bigMarkdown))
        )
        OrbReadCache.saveRowsMemoryOnly("mission_events_$id", events)
        val mission = OrbRow(
            id,
            mapOf("id" to id, "title" to "Rich mission", "status" to "completed", "project" to "demo")
        )
        rule.setContent {
            OrbConversationPage(core = core, project = project, initialMission = mission, onBack = {})
        }
        repeat(5) {
            rule.mainClock.advanceTimeBy(500)
            rule.waitForIdle()
        }
    }
}
