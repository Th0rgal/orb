package sh.sandboxed.dashboard.data

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import sh.sandboxed.dashboard.data.api.ApiService
import sh.sandboxed.dashboard.data.api.AskClient
import sh.sandboxed.dashboard.data.api.ControlWsClient
import sh.sandboxed.dashboard.data.api.DesktopStreamSocket
import sh.sandboxed.dashboard.data.api.Net
import sh.sandboxed.dashboard.data.api.SseClient
import sh.sandboxed.dashboard.data.api.TerminalSocket

class AppContainer(context: Context) {
    val appContext: Context = context.applicationContext
    // Network failures from background coroutines (e.g. SSE reconnect, OkHttp
    // async callbacks during airplane-mode flaps) used to escape uncaught and
    // kill the process. The handler swallows them with a log instead — UI
    // callers still see failures via their own `runCatching`.
    private val coroutineErrorHandler = CoroutineExceptionHandler { _, t ->
        Log.w("AppContainer", "Uncaught coroutine exception", t)
    }
    val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default + coroutineErrorHandler)
    val settings = SettingsStore(appContext)

    val cached: StateFlow<AppSettings> = settings.flow
        .stateIn(scope, SharingStarted.Eagerly, AppSettings())

    private fun snapshot(): AppSettings = cached.value

    val api: ApiService = ApiService(Net.httpClient) { snapshot() }
    val sse: SseClient = SseClient(api, Net.streamingClient)
    val controlWs: ControlWsClient = ControlWsClient(api, Net.streamingClient)
    val missionCache: MissionCache = MissionCache(appContext)
    val ask: AskClient = AskClient(api, Net.streamingClient)
    val terminal: TerminalSocket = TerminalSocket(Net.streamingClient) { snapshot() }
    val desktop: DesktopStreamSocket = DesktopStreamSocket(Net.streamingClient) { snapshot() }
    val fido: FidoChannel = FidoChannel(sse, api, scope, cached)
}
