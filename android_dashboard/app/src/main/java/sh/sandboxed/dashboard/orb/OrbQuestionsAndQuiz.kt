package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.HelpOutline
import androidx.compose.material.icons.filled.ListAlt
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

data class OrbQuestion(
    val id: String,
    val title: String,
    val prompt: String,
    val options: List<String>,
    val kind: Kind
) {
    enum class Kind {
        Permission,
        Plan,
        Question
    }
}

object OrbQuestionExtractor {
    fun extract(events: List<OrbRow>, messages: List<OrbRow>, status: String): OrbQuestion? {
        val lowerStatus = status.lowercase()
        val isActiveOrWaiting = lowerStatus in setOf(
            "active", "running", "working", "waiting", "pending", "blocked", "needs_input", "awaiting_approval"
        )

        var lastUserOrResolveIdx = -1
        events.forEachIndexed { idx, ev ->
            val type = (ev.str("type", "event_type", "kind") ?: "").lowercase()
            if (type in setOf("user_message", "permission_resolved", "approval_resolved", "question_answered", "tool_result")) {
                lastUserOrResolveIdx = idx
            }
        }

        val tail = if (lastUserOrResolveIdx + 1 < events.size) {
            events.subList(lastUserOrResolveIdx + 1, events.size)
        } else {
            emptyList()
        }

        for (ev in tail.asReversed()) {
            val type = (ev.str("type", "event_type", "kind") ?: "").lowercase()
            val data = ev.dict("data") ?: ev.raw

            if (type.contains("permission") || type.contains("approval") || OrbJSON.str(data, "permission", "approval_id") != null) {
                val cmd = OrbJSON.str(data, "command", "tool", "name", "action") ?: "Action"
                val desc = OrbJSON.str(data, "description", "reason", "prompt", "message")
                    ?: "Agent is requesting permission to run `$cmd`."
                val opts = OrbJSON.strList(data, "options").ifEmpty {
                    listOf("Approve", "Approve for session", "Decline")
                }
                return OrbQuestion(
                    id = ev.id,
                    title = "Permission required",
                    prompt = desc,
                    options = opts,
                    kind = OrbQuestion.Kind.Permission
                )
            }

            if (type.contains("question") || type == "ask_user" || type == "user_input_required") {
                val prompt = OrbJSON.str(data, "question", "prompt", "message", "text") ?: continue
                val opts = OrbJSON.strList(data, "options", "choices")
                return OrbQuestion(
                    id = ev.id,
                    title = OrbJSON.str(data, "title", "header") ?: "Question from agent",
                    prompt = prompt,
                    options = opts,
                    kind = OrbQuestion.Kind.Question
                )
            }

            val toolName = (OrbJSON.str(data, "name", "tool", "tool_name")
                ?: ev.str("name", "tool", "tool_name") ?: "").lowercase()
            if (toolName in setOf("askuserquestion", "ask_user_question", "ask_user", "request_approval", "exitplanmode", "exit_plan_mode")) {
                val input = OrbJSON.dict(data["input"]) ?: OrbJSON.dict(data["arguments"]) ?: data
                val prompt = OrbJSON.str(input, "question", "prompt", "plan", "description", "message")
                    ?: "Review and choose how to proceed."
                val opts = OrbJSON.strList(input, "options", "choices").ifEmpty {
                    if (toolName.contains("plan")) listOf("Approve plan", "Request changes") else emptyList()
                }
                return OrbQuestion(
                    id = ev.id,
                    title = if (toolName.contains("plan")) "Plan ready for review" else "Agent needs your input",
                    prompt = prompt,
                    options = opts,
                    kind = if (toolName.contains("plan")) OrbQuestion.Kind.Plan else OrbQuestion.Kind.Question
                )
            }
        }

        if (!isActiveOrWaiting && messages.isNotEmpty()) {
            val last = messages.last()
            val role = (last.str("role", "sender", "author") ?: "").lowercase()
            if (role == "assistant" || role == "agent") {
                val text = last.str("content", "text", "message") ?: ""
                val parsed = parseTrailingChoices(text)
                if (parsed != null) {
                    return OrbQuestion(
                        id = "msg-${last.id}",
                        title = "Suggested responses",
                        prompt = parsed.first,
                        options = parsed.second,
                        kind = OrbQuestion.Kind.Question
                    )
                }
            }
        }
        return null
    }

    private fun parseTrailingChoices(text: String): Pair<String, List<String>>? {
        val lines = text.split("\n")
            .map { it.trim() }
            .filter { it.isNotEmpty() }
        val tail = lines.takeLast(6)
        if (tail.isEmpty()) return null
        val questionLine = tail.lastOrNull { it.endsWith("?") } ?: return null
        val options = mutableListOf<String>()
        for (line in tail) {
            for (prefix in listOf("1. ", "2. ", "3. ", "4. ", "A) ", "B) ", "C) ", "D) ", "- [ ] ")) {
                if (line.startsWith(prefix)) {
                    val choice = line.drop(prefix.length).trim()
                    if (choice.isNotEmpty() && choice.length <= 70) {
                        options.add(choice)
                    }
                }
            }
        }
        if (options.size < 2) return null
        return questionLine to options
    }
}

@Composable
fun OrbQuestionCard(
    question: OrbQuestion,
    isSending: Boolean,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier
) {
    var customAnswer by remember(question.id) { mutableStateOf("") }
    val icon: ImageVector = when (question.kind) {
        OrbQuestion.Kind.Permission -> Icons.Default.Shield
        OrbQuestion.Kind.Plan -> Icons.Default.ListAlt
        OrbQuestion.Kind.Question -> Icons.Default.HelpOutline
    }
    val accentColor: Color = when (question.kind) {
        OrbQuestion.Kind.Permission -> OrbStyle.warning
        OrbQuestion.Kind.Plan -> Color.White
        OrbQuestion.Kind.Question -> OrbStyle.warning
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.borderStrong, RoundedCornerShape(18.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = accentColor,
                modifier = Modifier.size(14.dp)
            )
            Text(
                text = question.title,
                color = Color.White,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f)
            )
            Box(
                modifier = Modifier
                    .size(22.dp)
                    .clip(CircleShape)
                    .background(OrbStyle.card)
                    .orbPressClickable { onDismiss() },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Default.Close,
                    contentDescription = "Dismiss",
                    tint = OrbStyle.textMuted,
                    modifier = Modifier.size(11.dp)
                )
            }
        }

        Text(
            text = question.prompt,
            color = OrbStyle.textSecondary,
            fontSize = 14.sp,
            maxLines = 6,
            overflow = TextOverflow.Ellipsis
        )

        if (question.options.isNotEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                question.options.forEach { option ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(11.dp))
                            .background(OrbStyle.card)
                            .border(1.dp, OrbStyle.border, RoundedCornerShape(11.dp))
                            .orbPressClickable(enabled = !isSending) { onSelect(option) }
                            .padding(horizontal = 12.dp, vertical = 9.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = option,
                            color = Color.White,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.weight(1f)
                        )
                        Icon(
                            imageVector = Icons.Default.ChevronRight,
                            contentDescription = null,
                            tint = OrbStyle.textMuted,
                            modifier = Modifier.size(12.dp)
                        )
                    }
                }
            }
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(11.dp))
                .background(OrbStyle.card)
                .border(1.dp, OrbStyle.border, RoundedCornerShape(11.dp))
                .padding(horizontal = 11.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Box(modifier = Modifier.weight(1f)) {
                if (customAnswer.isEmpty()) {
                    Text(
                        text = "Or type a custom response…",
                        color = OrbStyle.textMuted,
                        fontSize = 14.sp
                    )
                }
                BasicTextField(
                    value = customAnswer,
                    onValueChange = { customAnswer = it },
                    textStyle = TextStyle(color = Color.White, fontSize = 14.sp),
                    cursorBrush = SolidColor(Color.White),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            }
            if (customAnswer.trim().isNotEmpty()) {
                Box(
                    modifier = Modifier
                        .size(24.dp)
                        .clip(CircleShape)
                        .background(Color.White)
                        .orbPressClickable(enabled = !isSending) {
                            val ans = customAnswer.trim()
                            customAnswer = ""
                            onSelect(ans)
                        },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = Icons.Default.ArrowUpward,
                        contentDescription = "Send",
                        tint = Color.Black,
                        modifier = Modifier.size(14.dp)
                    )
                }
            }
        }
    }
}

data class OrbQuizQuestion(
    val id: String,
    val prompt: String,
    val options: List<String>,
    val correctIndex: Int?,
    val explanation: String?
)

data class OrbQuizPayload(
    val title: String,
    val questions: List<OrbQuizQuestion>
)

sealed class OrbSegment(open val id: String) {
    data class Markdown(override val id: String, val text: String) : OrbSegment(id)
    data class Quiz(override val id: String, val payload: OrbQuizPayload) : OrbSegment(id)
}

object OrbQuizParser {
    private val fenceRegex = Regex("```(?:quiz|orb-quiz|qcm)\\s*\\n([\\s\\S]*?)```")

    fun split(markdown: String): List<OrbSegment> {
        val matches = fenceRegex.findAll(markdown).toList()
        if (matches.isEmpty()) {
            return listOf(OrbSegment.Markdown("md-0", markdown))
        }
        val segments = mutableListOf<OrbSegment>()
        var cursor = 0
        matches.forEachIndexed { idx, match ->
            if (match.range.first > cursor) {
                val before = markdown.substring(cursor, match.range.first)
                    .trim { it <= ' ' || it == '\n' }
                if (before.isNotEmpty()) {
                    segments.add(OrbSegment.Markdown("md-pre-$idx", before))
                }
            }
            val rawBlock = match.groupValues[1]
            val quiz = parseQuizBlock(rawBlock, idx)
            if (quiz != null) {
                segments.add(OrbSegment.Quiz("quiz-$idx", quiz))
            } else {
                segments.add(OrbSegment.Markdown("md-raw-$idx", match.value))
            }
            cursor = match.range.last + 1
        }
        if (cursor < markdown.length) {
            val tail = markdown.substring(cursor).trim { it <= ' ' || it == '\n' }
            if (tail.isNotEmpty()) {
                segments.add(OrbSegment.Markdown("md-tail", tail))
            }
        }
        return segments
    }

    private fun parseQuizBlock(raw: String, seed: Int): OrbQuizPayload? {
        val trimmed = raw.trim()
        val parsed = OrbJSON.parse(trimmed)
        if (parsed != null) {
            val dict = OrbJSON.dict(parsed)
            if (dict != null) {
                val title = OrbJSON.str(dict, "title", "name") ?: "Quick check"
                val rawQuestions = OrbJSON.dictList(dict["questions"]).ifEmpty { listOf(dict) }
                val questions = rawQuestions.mapIndexedNotNull { qIdx, qDict ->
                    parseQuestionDict(qDict, "$seed-$qIdx")
                }
                if (questions.isNotEmpty()) {
                    return OrbQuizPayload(title = title, questions = questions)
                }
            }
            val list = OrbJSON.dictList(parsed)
            if (list.isNotEmpty()) {
                val questions = list.mapIndexedNotNull { qIdx, qDict ->
                    parseQuestionDict(qDict, "$seed-$qIdx")
                }
                if (questions.isNotEmpty()) {
                    return OrbQuizPayload(title = "Quick check", questions = questions)
                }
            }
        }
        return parseLineQuiz(trimmed, seed)
    }

    private fun parseQuestionDict(dict: OrbDict, id: String): OrbQuizQuestion? {
        val prompt = OrbJSON.str(dict, "question", "prompt", "q", "title") ?: return null
        val options = OrbJSON.strList(dict, "options", "choices", "answers")
        if (options.size < 2) return null
        var correct = OrbJSON.int(dict, "answer", "correct", "correct_index", "correctIndex")
        if (correct == null) {
            val answerStr = OrbJSON.str(dict, "answer", "correct")
            if (answerStr != null) {
                correct = options.indexOfFirst { it.equals(answerStr, ignoreCase = true) }
                    .takeIf { it >= 0 }
                if (correct == null && answerStr.length == 1) {
                    val ch = answerStr.uppercase()[0]
                    if (ch in 'A'..'H') {
                        val letterIdx = ch - 'A'
                        if (letterIdx < options.size) correct = letterIdx
                    }
                }
            }
        }
        val explanation = OrbJSON.str(dict, "explanation", "rationale", "why", "note")
        return OrbQuizQuestion(
            id = id,
            prompt = prompt,
            options = options,
            correctIndex = correct,
            explanation = explanation
        )
    }

    private fun parseLineQuiz(raw: String, seed: Int): OrbQuizPayload? {
        var prompt = ""
        val options = mutableListOf<String>()
        var correctIndex: Int? = null
        var explanation: String? = null

        raw.lineSequence().map { it.trim() }.filter { it.isNotEmpty() }.forEach { line ->
            val lower = line.lowercase()
            when {
                lower.startsWith("q:") || lower.startsWith("question:") -> {
                    val idx = line.indexOf(':')
                    if (idx >= 0) prompt = line.substring(idx + 1).trim()
                }
                lower.startsWith("explain:") || lower.startsWith("explanation:") -> {
                    val idx = line.indexOf(':')
                    if (idx >= 0) explanation = line.substring(idx + 1).trim()
                }
                line.startsWith("- [x]") || line.startsWith("* [x]") || line.startsWith("-[x]") -> {
                    correctIndex = options.size
                    options.add(line.drop(5).trim())
                }
                line.startsWith("- [ ]") || line.startsWith("* [ ]") || line.startsWith("-[ ]") -> {
                    options.add(line.drop(5).trim())
                }
                line.startsWith("- ") || line.startsWith("* ") -> {
                    var opt = line.drop(2).trim()
                    if (opt.endsWith("*")) {
                        correctIndex = options.size
                        opt = opt.dropLast(1).trim()
                    }
                    options.add(opt)
                }
                prompt.isEmpty() -> prompt = line
            }
        }

        if (prompt.isEmpty() || options.size < 2) return null
        return OrbQuizPayload(
            title = "Quick check",
            questions = listOf(
                OrbQuizQuestion(
                    id = "$seed-0",
                    prompt = prompt,
                    options = options,
                    correctIndex = correctIndex,
                    explanation = explanation
                )
            )
        )
    }
}

@Composable
fun OrbQuizCard(
    payload: OrbQuizPayload,
    onSubmitAnswer: ((String) -> Unit)? = null,
    modifier: Modifier = Modifier
) {
    var currentIndex by remember { mutableIntStateOf(0) }
    val selectedByQuestion = remember { mutableStateMapOf<String, Int>() }
    val revealedByQuestion = remember { mutableStateMapOf<String, Boolean>() }

    if (payload.questions.isEmpty()) return
    val q = payload.questions[minOf(currentIndex, payload.questions.lastIndex)]
    val selected = selectedByQuestion[q.id]
    val revealed = revealedByQuestion[q.id] == true

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.borderStrong, RoundedCornerShape(16.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Icon(
                    imageVector = Icons.Default.ListAlt,
                    contentDescription = null,
                    tint = OrbStyle.textSecondary,
                    modifier = Modifier.size(12.dp)
                )
                Text(
                    text = payload.title.uppercase(),
                    color = OrbStyle.textSecondary,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 0.6.sp
                )
            }
            Spacer(modifier = Modifier.weight(1f))
            if (payload.questions.size > 1) {
                Text(
                    text = "${currentIndex + 1} / ${payload.questions.size}",
                    color = OrbStyle.textMuted,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                    fontFamily = FontFamily.Monospace
                )
            }
        }

        OrbRichText(markdown = q.prompt, tone = OrbRichTextTone.Primary)

        Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
            q.options.forEachIndexed { idx, opt ->
                val isSelected = selected == idx
                val isCorrect = q.correctIndex == idx
                val borderColor = when {
                    revealed && isCorrect -> OrbStyle.success.copy(alpha = 0.7f)
                    revealed && isSelected && q.correctIndex != null && !isCorrect -> OrbStyle.error.copy(alpha = 0.7f)
                    isSelected -> Color.White.copy(alpha = 0.45f)
                    else -> OrbStyle.border
                }
                val bgColor = when {
                    revealed && isCorrect -> OrbStyle.success.copy(alpha = 0.14f)
                    revealed && isSelected && q.correctIndex != null && !isCorrect -> OrbStyle.error.copy(alpha = 0.14f)
                    isSelected -> OrbStyle.elevated
                    else -> OrbStyle.card
                }
                val badgeBg = when {
                    revealed && isCorrect -> OrbStyle.success
                    revealed && isSelected && q.correctIndex != null && !isCorrect -> OrbStyle.error
                    isSelected -> Color.White
                    else -> OrbStyle.elevated
                }
                val badgeFg = if ((revealed && isCorrect) || isSelected) Color.Black else OrbStyle.textSecondary

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(bgColor)
                        .border(1.dp, borderColor, RoundedCornerShape(12.dp))
                        .orbPressClickable {
                            selectedByQuestion[q.id] = idx
                            if (q.correctIndex != null) {
                                revealedByQuestion[q.id] = true
                            }
                        }
                        .padding(horizontal = 11.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(22.dp)
                            .clip(CircleShape)
                            .background(badgeBg),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = ('A' + idx).toString(),
                            color = badgeFg,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            fontFamily = FontFamily.Monospace
                        )
                    }
                    Box(modifier = Modifier.weight(1f)) {
                        OrbRichText(markdown = opt, tone = OrbRichTextTone.Primary)
                    }
                    if (revealed && isCorrect) {
                        Icon(
                            imageVector = Icons.Default.Check,
                            contentDescription = null,
                            tint = OrbStyle.success,
                            modifier = Modifier.size(15.dp)
                        )
                    } else if (revealed && isSelected && q.correctIndex != null && !isCorrect) {
                        Icon(
                            imageVector = Icons.Default.Close,
                            contentDescription = null,
                            tint = OrbStyle.error,
                            modifier = Modifier.size(15.dp)
                        )
                    }
                }
            }
        }

        if (revealed && !q.explanation.isNullOrEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                HorizontalDivider(color = OrbStyle.border)
                OrbRichText(markdown = q.explanation, tone = OrbRichTextTone.Secondary)
            }
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            if (selected != null && q.correctIndex == null && onSubmitAnswer != null) {
                val chosen = q.options[selected]
                Row(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(Color.White)
                        .orbPressClickable { onSubmitAnswer(chosen) }
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.ArrowUpward,
                        contentDescription = null,
                        tint = Color.Black,
                        modifier = Modifier.size(12.dp)
                    )
                    Text(
                        text = "Send \"$chosen\"",
                        color = Color.Black,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }

            Spacer(modifier = Modifier.weight(1f))

            if (payload.questions.size > 1) {
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(OrbStyle.card)
                        .orbPressClickable(enabled = currentIndex > 0) {
                            if (currentIndex > 0) currentIndex -= 1
                        }
                        .padding(horizontal = 10.dp, vertical = 5.dp)
                ) {
                    Text(
                        text = "Prev",
                        color = if (currentIndex > 0) OrbStyle.textSecondary else OrbStyle.textMuted,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium
                    )
                }
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(OrbStyle.card)
                        .orbPressClickable(enabled = currentIndex + 1 < payload.questions.size) {
                            if (currentIndex + 1 < payload.questions.size) currentIndex += 1
                        }
                        .padding(horizontal = 10.dp, vertical = 5.dp)
                ) {
                    Text(
                        text = "Next",
                        color = if (currentIndex + 1 < payload.questions.size) Color.White else OrbStyle.textMuted,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium
                    )
                }
            }
        }
    }
}

@Composable
fun OrbRemoteLog(
    title: String,
    log: String?,
    onRetry: (() -> Unit)? = null,
    modifier: Modifier = Modifier
) {
    var expanded by remember { mutableStateOf(false) }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(OrbStyle.surface)
            .border(1.dp, OrbStyle.border, RoundedCornerShape(12.dp))
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Icon(
                imageVector = Icons.Default.HelpOutline,
                contentDescription = null,
                tint = OrbStyle.warning,
                modifier = Modifier.size(12.dp)
            )
            Text(
                text = title,
                color = OrbStyle.textSecondary,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f)
            )
            if (onRetry != null) {
                Row(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(OrbStyle.card)
                        .orbPressClickable { onRetry() }
                        .padding(horizontal = 9.dp, vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Replay,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(11.dp)
                    )
                    Text(
                        text = "Retry",
                        color = Color.White,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                }
            }
            if (!log.isNullOrEmpty()) {
                Row(
                    modifier = Modifier.orbPressClickable { expanded = !expanded },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        imageVector = if (expanded) Icons.Default.ExpandMore else Icons.Default.ChevronRight,
                        contentDescription = null,
                        tint = OrbStyle.textMuted,
                        modifier = Modifier.size(10.dp)
                    )
                    Text(
                        text = "Remote log",
                        color = OrbStyle.textMuted,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                }
            }
        }

        if (expanded && !log.isNullOrEmpty()) {
            Text(
                text = log,
                color = OrbStyle.textSecondary,
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color.Black.copy(alpha = 0.4f))
                    .padding(9.dp)
            )
        }
    }
}
