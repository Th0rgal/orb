package sh.sandboxed.dashboard.orb

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrbMachinesSettingsPage(
    core: OrbCore,
    onBack: () -> Unit
) {
    val scope = rememberCoroutineScope()
    val cachedNodes by core.nodes.collectAsState()
    var nodes by remember(cachedNodes) { mutableStateOf(cachedNodes) }
    var expandedNodeIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var isRefreshing by remember { mutableStateOf(false) }
    var errorBanner by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var computers by remember { mutableStateOf<List<OrbRow>>(emptyList()) }
    var computersReady by remember { mutableStateOf(false) }

    suspend fun loadMachines() {
        // Computers are independent of the fleet: one failing never hides the other.
        try {
            computers = loadClientComputers(core)
            computersReady = true
        } catch (_: Throwable) {
        }
        try {
            val remoteObj = core.fetchDict("/api/remote-nodes")
            nodes = OrbJSON.dictList(remoteObj["nodes"]).map { OrbRow(it) }
            errorBanner = null
        } catch (e: Throwable) {
            errorBanner = "Fleet unavailable. ${e.message ?: ""}"
        }
    }

    LaunchedEffect(Unit) {
        isRefreshing = true
        loadMachines()
        isRefreshing = false
    }

    fun toggleCordon(node: OrbRow) {
        if (busy) return
        busy = true
        val nodeId = node.str("id", "name") ?: node.id
        val cordoned = node.bool("cordoned", "paused") == true
        val action = if (cordoned) "uncordon" else "cordon"
        scope.launch {
            try {
                core.request("/api/nodes/${core.encodeComponent(nodeId)}/$action", method = "POST")
                loadMachines()
                core.refreshAll()
            } catch (e: Throwable) {
                errorBanner = e.message
            } finally {
                busy = false
            }
        }
    }

    fun formatBytesGiB(totalBytes: Double?, availBytes: Double?): String {
        if (totalBytes == null || availBytes == null || totalBytes <= 0.0) return "Unavailable"
        val usedGiB = (totalBytes - availBytes) / 1073741824.0
        val totalGiB = totalBytes / 1073741824.0
        return String.format("%.1f / %.1f GiB", usedGiB, totalGiB)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(OrbStyle.background)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, CircleShape)
                    .orbPressClickable { onBack() },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = Color.White,
                    modifier = Modifier.size(17.dp)
                )
            }
            Text(
                text = "Machines",
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center
            )
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(OrbStyle.surface)
                    .border(1.dp, OrbStyle.border, CircleShape)
                    .orbPressClickable {
                        scope.launch {
                            isRefreshing = true
                            loadMachines()
                            core.refreshAll()
                            isRefreshing = false
                        }
                    },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Default.Refresh,
                    contentDescription = "Refresh",
                    tint = Color.White,
                    modifier = Modifier.size(16.dp)
                )
            }
        }

        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                scope.launch {
                    isRefreshing = true
                    loadMachines()
                    core.refreshAll()
                    isRefreshing = false
                }
            },
            modifier = Modifier.fillMaxSize()
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 20.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                errorBanner?.let { err ->
                    item { OrbNotice(title = err, log = core.lastErrorLog.collectAsState().value) }
                }

                item { OrbComputersBlock(core = core, computers = computers, ready = computersReady) }

                // Section("Fleet") matching OrbMachinesSettings.swift
                item {
                    Text(
                        text = "FLEET",
                        color = OrbStyle.textMuted,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 0.7.sp
                    )
                }

                if (nodes.isEmpty() && !isRefreshing) {
                    item {
                        Text(
                            text = "No remote nodes registered.",
                            color = OrbStyle.textMuted,
                            fontSize = 14.sp
                        )
                    }
                } else {
                    item {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(16.dp))
                                .background(OrbStyle.surface)
                                .border(1.dp, OrbStyle.border, RoundedCornerShape(16.dp))
                        ) {
                            nodes.forEachIndexed { idx, node ->
                                val nodeId = node.str("id", "name") ?: node.id
                                val statusText = node.str("status", "state") ?: "online"
                                val cordoned = node.bool("cordoned", "paused") == true
                                val subtitle = statusText + if (cordoned) " · New jobs paused" else ""
                                val expanded = expandedNodeIds.contains(nodeId)

                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .orbPressClickable {
                                            expandedNodeIds = if (expanded) expandedNodeIds - nodeId else expandedNodeIds + nodeId
                                        }
                                        .padding(horizontal = 16.dp, vertical = 13.dp),
                                    verticalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Column(
                                            modifier = Modifier.weight(1f),
                                            verticalArrangement = Arrangement.spacedBy(2.dp)
                                        ) {
                                            Text(
                                                text = nodeId,
                                                color = Color.White,
                                                fontSize = 15.sp,
                                                fontWeight = FontWeight.Medium
                                            )
                                            Text(
                                                text = subtitle,
                                                color = OrbStyle.textSecondary,
                                                fontSize = 12.sp
                                            )
                                        }
                                        Icon(
                                            imageVector = Icons.Default.ChevronRight,
                                            contentDescription = null,
                                            tint = OrbStyle.textMuted,
                                            modifier = Modifier.size(16.dp)
                                        )
                                    }

                                    if (expanded) {
                                        val activeJobs = node.int("active_jobs")?.toString() ?: "Unavailable"
                                        val memStr = formatBytesGiB(
                                            node.double("mem_total_bytes"),
                                            node.double("mem_available_bytes")
                                        )
                                        val diskStr = formatBytesGiB(
                                            node.double("disk_total_bytes"),
                                            node.double("disk_available_bytes")
                                        )
                                        val history = node.rows("resource_history")
                                        val lastSample = history.lastOrNull()
                                        val cpuVal = lastSample?.double("cpu")?.let { "${it.roundToInt()}%" }
                                            ?: node.double("cpu_total")?.let { "${it.roundToInt()} cores" }
                                        val gpuVal = lastSample?.double("gpu")?.let { "${it.roundToInt()}%" }

                                        Column(
                                            modifier = Modifier.fillMaxWidth(),
                                            verticalArrangement = Arrangement.spacedBy(6.dp)
                                        ) {
                                            OrbKeyValueLine("Status", statusText)
                                            OrbKeyValueLine("Active jobs", activeJobs)
                                            OrbKeyValueLine("Memory", memStr)
                                            OrbKeyValueLine("Disk", diskStr)
                                            if (cpuVal != null) {
                                                OrbKeyValueLine("CPU", cpuVal)
                                            }
                                            if (gpuVal != null) {
                                                OrbKeyValueLine("GPU", gpuVal)
                                            }
                                            Spacer(modifier = Modifier.height(4.dp))
                                            Box(
                                                modifier = Modifier
                                                    .clip(CircleShape)
                                                    .background(OrbStyle.card)
                                                    .border(1.dp, OrbStyle.border, CircleShape)
                                                    .orbPressClickable { toggleCordon(node) }
                                                    .padding(horizontal = 12.dp, vertical = 6.dp)
                                            ) {
                                                Text(
                                                    text = if (cordoned) "Allow new jobs" else "Pause new jobs",
                                                    color = OrbStyle.inboxBlue,
                                                    fontSize = 13.sp,
                                                    fontWeight = FontWeight.Medium,
                                                    maxLines = 1,
                                                    softWrap = false
                                                )
                                            }
                                        }
                                    }
                                }

                                if (idx < nodes.lastIndex) {
                                    HorizontalDivider(
                                        color = OrbStyle.border,
                                        modifier = Modifier.padding(start = 16.dp)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun OrbKeyValueLine(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = label,
            color = Color.White,
            fontSize = 13.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f)
        )
        Text(
            text = value,
            color = OrbStyle.textSecondary,
            fontSize = 13.sp,
            maxLines = 1,
            softWrap = false
        )
    }
}

@Composable
internal fun OrbMiniField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(text = label, color = OrbStyle.textMuted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(OrbStyle.card)
                .border(1.dp, OrbStyle.border, RoundedCornerShape(10.dp))
                .padding(horizontal = 10.dp, vertical = 9.dp)
        ) {
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                cursorBrush = SolidColor(Color.White),
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}
