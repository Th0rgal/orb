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

    /** A payload that states neither the mode nor the countries confirms nothing. */
    fun route(payload: Any?): OrbDict? {
        val route = OrbJSON.dict(payload) ?: return null
        val mode = route["mode"]
        return route.takeIf { (mode == "vpn" || mode == "direct") && it["countries"] is List<*> }
    }

    fun view(route: OrbDict, nativeAccount: Boolean): View {
        val selected = route["country"] as? String ?: ""
        val offered = (route["countries"] as? List<*>)?.filterIsInstance<String>().orEmpty()
        val editable = route["can_configure"] == true
        val blocked = route["status"] == "blocked"
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
                route["status"] == "verified" -> {
                    val exits = (route["exits"] as? List<*>)?.filterIsInstance<String>().orEmpty().joinToString(", ")
                    "Verified exit · ${route["server"] as? String ?: ""} · $exits"
                }
                blocked -> route["message"] as? String ?: "The VPN route is unavailable."
                else -> ""
            },
            retry = blocked,
            poll = pending,
        )
    }

    fun write(country: String): Map<String, String> =
        if (country.isEmpty()) mapOf("mode" to "direct") else mapOf("mode" to "vpn", "country" to country)

    /** Core answers an unknown endpoint with its own path; a missing account does not. */
    fun missingSetting(status: Int?, body: String?, path: String): Boolean {
        if (status != 404 || body == null) return false
        val parsed = OrbJSON.dict(OrbJSON.parse(body)) ?: return false
        return parsed["error"] == "not_found"
    }

    fun routerAccess(payload: Any?): Boolean? = OrbJSON.dict(payload)?.get("allowed") as? Boolean

    /** An older Core gets the version requirement instead of its raw 404. */
    fun readError(error: Throwable, path: String, update: String, unavailable: String? = null): String =
        if (error is OrbError && missingSetting(error.status, error.body, path)) update
        else unavailable ?: error.localizedMessage ?: "Connection settings unavailable."
}
