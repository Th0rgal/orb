package sh.sandboxed.dashboard.orb

/** Account connection and alternative-router settings as Core reports them
 *  (Orb: accountVpn.ts), checked against `shared/orb-spec/fixtures/account-vpn.json`. */
object OrbAccountVpn {
    data class View(
        /** Saved country, or "" for Direct. */
        val selected: String,
        /** Selectable countries: the saved one first, then Core's imported profiles. */
        val countries: List<String>,
        val editable: Boolean,
        /** A native account must confirm a Direct route it never chose. */
        val confirmDirect: Boolean,
        val notice: String,
        val status: String,
        val retry: Boolean,
        /** Verification is still running: reread until it settles. */
        val poll: Boolean,
    )

    /** Orders the row's reads and writes: a selection is never dropped for a
     *  read in flight, and only the newest request is shown. */
    data class Requests(val saving: Boolean = false, val latest: Int = 0) {
        /** Null while a selection is being saved: nothing else starts until it settles. */
        fun start(write: Boolean): Requests? = if (saving) null else Requests(true, latest + 1)
        fun current(request: Int): Boolean = request == latest
        fun saved(): Requests = copy(saving = false)
    }

    object Labels {
        const val vpnUpdate = "Update Core to configure account VPNs."
        const val routerUpdate = "Update Core to configure alternative router access."
        const val routeUnavailable = "Connection settings unavailable."
        const val routerUnavailable = "Router access is unavailable."
        const val routerUnconfirmed = "Could not confirm the change. Check the current setting before retrying."
    }

    /** A payload that states neither the mode nor the countries confirms nothing,
     *  and neither does a VPN route that does not name its country. */
    fun route(payload: Any?): OrbDict? {
        val route = OrbJSON.dict(payload) ?: return null
        if (route["countries"] !is List<*>) return null
        return when (route["mode"]) {
            "vpn" -> route
            "direct" -> route
            else -> null
        }
    }

    fun view(route: OrbDict, nativeAccount: Boolean): View {
        // Only a VPN route has a country, an exit or a failure to retry.
        val vpn = route["mode"] == "vpn"
        val selected = route["country"] as? String ?: ""
        val offered = (route["countries"] as? List<*>)?.filterIsInstance<String>().orEmpty().filter { it.isNotEmpty() }
        val editable = route["can_configure"] == true
        val blocked = vpn && route["status"] == "blocked"
        val pending = blocked && route["reason"] == "vpn_awaiting_verification"
        return View(
            selected = selected,
            countries = (listOf(selected) + offered).filter { it.isNotEmpty() }.distinct(),
            editable = editable,
            confirmDirect = nativeAccount && editable && route["mode"] == "direct" && route["saved"] != true,
            notice = when {
                !editable -> route["configuration_message"] as? String ?: "VPN routing is unavailable for this credential."
                offered.isEmpty() -> "Import a named server profile in AirVPN Settings to enable VPN routing."
                else -> ""
            },
            status = when {
                vpn && route["status"] == "verified" -> {
                    val exits = (route["exits"] as? List<*>)?.filterIsInstance<String>().orEmpty().joinToString(", ")
                    "Verified exit · ${route["server"] as? String ?: ""} · $exits"
                }
                blocked -> route["message"] as? String ?: "The VPN route is unavailable."
                else -> ""
            },
            retry = blocked && !pending,
            poll = pending,
        )
    }

    fun write(country: String): Map<String, String> =
        if (country.isEmpty()) mapOf("mode" to "direct") else mapOf("mode" to "vpn", "country" to country)

    /** Core answers an unknown endpoint with its own path; a missing account does not. */
    fun missingSetting(status: Int?, body: String?, path: String): Boolean {
        if (status != 404 || body == null) return false
        val parsed = OrbJSON.dict(OrbJSON.parse(body)) ?: return false
        return parsed["error"] == "not_found" && parsed["path"] == path
    }

    fun routerAccess(payload: Any?): Boolean? = OrbJSON.dict(payload)?.get("allowed") as? Boolean

    /** An older Core gets the version requirement instead of its raw 404. */
    fun readError(error: Throwable, path: String, update: String, unavailable: String): String =
        if (error is OrbError && missingSetting(error.status, error.body, path)) update else unavailable
}
