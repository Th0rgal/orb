package sh.sandboxed.dashboard.orb

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException

/** Same transition as desktop/iOS; an empty choice disables without forgetting. */
object OrbInboxSummaryChoice {
    data class Selection(val aiSummary: Boolean, val model: String)
    fun apply(model: String, choice: String): Selection {
        val selected = choice.trim()
        return Selection(selected.isNotEmpty(), selected.ifEmpty { model })
    }
}

@Composable
fun OrbInboxSettingsPage(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val core = OrbCore.shared
    val endpoint by core.baseURLFlow.collectAsState()
    val token by core.tokenFlow.collectAsState()
    var expanded by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var customModel by remember { mutableStateOf("") }
    var choices by remember { mutableStateOf(emptyList<String>()) }
    val models = (OrbInboxSettings.modelPresets.map { it.id } + choices + OrbInboxSettings.model).filter { it.isNotBlank() }.distinct()
    fun choose(choice: String) {
        val next = OrbInboxSummaryChoice.apply(OrbInboxSettings.model, choice)
        OrbInboxSettings.update(newAiSummary = next.aiSummary, newModel = next.model)
        expanded = false
    }
    LaunchedEffect(endpoint, token) {
        choices = emptyList()
        // Catalog failure must not hide saved/custom choices or change preferences.
        suspend fun read(path: String): Any? = try { OrbCore.shared.request(path) }
            catch (e: CancellationException) { throw e }
            catch (_: Exception) { null }
        val chains = OrbJSON.dictList(read("/api/model-routing/chains"))
        val providers = OrbJSON.dictList(OrbJSON.dict(read("/api/providers?include_all=true&include_unverified=true"))?.get("providers"))
        choices = chains.mapNotNull { it["id"] as? String } + providers.flatMap { provider ->
            val id = provider["id"] as? String ?: return@flatMap emptyList()
            OrbJSON.dictList(provider["models"]).mapNotNull { model -> (model["id"] as? String)?.let { "$id/$it" } }
        }
    }
    Column(modifier.fillMaxSize().background(OrbStyle.background).verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = OrbStyle.textPrimary) }
            Text("Inbox", color = OrbStyle.textPrimary, style = MaterialTheme.typography.titleLarge)
        }
        Text("AI summaries", color = OrbStyle.textPrimary, style = MaterialTheme.typography.titleMedium)
        Text("Choose a model or routing chain for Inbox digests. Off keeps your last choice.", color = OrbStyle.textSecondary)
        Box {
            OutlinedButton(onClick = { expanded = true }, modifier = Modifier.semantics { contentDescription = "AI summaries: " + if (OrbInboxSettings.aiSummary) OrbInboxSettings.model else "Off" }) {
                Text(if (OrbInboxSettings.aiSummary) OrbInboxSettings.model else "Off")
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                DropdownMenuItem(text = { Text("Off") }, onClick = { choose("") })
                models.forEach { model -> DropdownMenuItem(text = { Text(model) }, onClick = { choose(model) }) }
                DropdownMenuItem(text = { Text("Custom model or chain…") }, onClick = {
                    customModel = OrbInboxSettings.model; expanded = false; editing = true
                })
            }
        }
    }
    if (editing) AlertDialog(onDismissRequest = { editing = false }, title = { Text("Custom model or chain") }, text = {
        OutlinedTextField(value = customModel, onValueChange = { customModel = it }, label = { Text("Model or chain ID") }, singleLine = true)
    }, confirmButton = {
        TextButton(enabled = customModel.isNotBlank(), onClick = { choose(customModel); editing = false }) { Text("Use model") }
    }, dismissButton = { TextButton(onClick = { editing = false }) { Text("Cancel") } })
}
