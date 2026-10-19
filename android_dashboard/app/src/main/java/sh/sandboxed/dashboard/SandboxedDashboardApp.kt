package sh.sandboxed.dashboard

import android.app.Application
import sh.sandboxed.dashboard.data.AppContainer

class SandboxedDashboardApp : Application() {
    /** Legacy container: built lazily so nothing in it runs at app start. */
    val container: AppContainer by lazy { AppContainer(this) }
}
