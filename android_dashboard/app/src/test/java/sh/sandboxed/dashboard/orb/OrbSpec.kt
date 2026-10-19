package sh.sandboxed.dashboard.orb

import java.io.File

/** Loads shared/orb-spec files (path set by Gradle; falls back to a repo-relative path). */
object OrbSpec {
    private val dir: File by lazy {
        System.getProperty("orb.spec.dir")?.let(::File)?.takeIf { it.isDirectory }
            ?: listOf("../shared/orb-spec", "../../shared/orb-spec").map(::File).first { it.isDirectory }
    }

    fun dict(name: String): OrbDict = OrbJSON.dict(OrbJSON.parse(File(dir, name).readText()))
        ?: error("could not parse $name")
}
