package sh.sandboxed.dashboard.orb

object OrbRoutingProvider {
    fun find(catalog: List<OrbRow>, id: String): OrbRow? =
        catalog.firstOrNull { it.id == id } ?: catalog.firstOrNull {
            it.id.startsWith("custom:") && (it.id.removePrefix("custom:") == id ||
                it.str("name").orEmpty().lowercase().replace(Regex("[^a-z0-9]"), "") == id)
        }
    fun label(catalog: List<OrbRow>, id: String): String =
        find(catalog, id)?.str("name")?.takeIf { it.isNotEmpty() } ?: id
}
