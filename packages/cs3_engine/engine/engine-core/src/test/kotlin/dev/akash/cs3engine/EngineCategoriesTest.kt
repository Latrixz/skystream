package dev.akash.cs3engine

import android.content.Context
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.SearchResponseList
import com.lagradost.cloudstream3.TvType
import com.lagradost.cloudstream3.newMovieSearchResponse
import com.lagradost.cloudstream3.newSearchResponseList
import com.lagradost.cloudstream3.plugins.Plugin
import kotlinx.coroutines.runBlocking
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/** categories and categoryPage call an extension's csCategories and csCategoryPage (see [CategoryCalls]). */
class EngineCategoriesTest {
    private object TestLoader : PluginLoader {
        override fun prepare(file: File) = PreparedPlugin(EngineCategoriesTest::class.java.classLoader)
    }

    private fun cs3(className: String): File {
        val file = File.createTempFile("engine-categories", ".cs3").apply { deleteOnExit() }
        ZipOutputStream(file.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("manifest.json"))
            zip.write("""{"name":"Categorised","pluginClassName":"$className","version":1}""".toByteArray())
            zip.closeEntry()
        }
        return file
    }

    @Suppress("UNCHECKED_CAST")
    private suspend fun Engine.call(method: String, vararg pairs: Pair<String, Any?>) =
        execute(method, Json.mapper.valueToTree(mapOf(*pairs))) as Map<String, Any?>

    private suspend fun <T> withPlugin(block: suspend (Engine, String) -> T): T {
        val engine = Engine(TestLoader, { Context() }, "test")
        val file = cs3(CategorisedPlugin::class.java.name)
        engine.execute("loadPlugin", Json.mapper.valueToTree(mapOf("path" to file.path)))
        return try {
            block(engine, file.path)
        } finally {
            engine.execute("unloadPlugin", Json.mapper.valueToTree(mapOf("path" to file.path)))
        }
    }

    @Test
    fun `the engine tells extensions it shows categories`() {
        Engine(TestLoader, { Context() }, "test")
        assertEquals("true", System.getProperty("cs3engine.categories"))
    }

    @Test
    @Suppress("UNCHECKED_CAST")
    fun `categories are the extension's, kept to the contract's shape`() = runBlocking {
        withPlugin { engine, path ->
            val answer = engine.call("categories", "provider" to "Categorised", "plugin" to path)
            assertEquals(true, answer["supported"])
            val categories = answer["categories"] as List<Map<String, Any?>>
            // The one without a name is dropped; a numeric id comes as text.
            assertEquals(listOf("3", "4"), categories.map { it["id"] })
            val movies = categories.first()
            assertEquals("电影", movies["name"])
            val filters = movies["filters"] as List<Map<String, Any?>>
            // A filter with no options is dropped; a label defaults to the value.
            assertEquals(listOf("region"), filters.map { it["key"] })
            assertEquals(listOf(mapOf("value" to "韩国", "label" to "韩国"), mapOf("value" to "日本", "label" to "Japan")), filters.single()["options"])
            assertEquals(listOf("2", "0"), (movies["sorts"] as List<Map<String, Any?>>).map { it["value"] })
        }
    }

    @Test
    @Suppress("UNCHECKED_CAST")
    fun `a page is the extension's for the filters, query and page asked for`() = runBlocking {
        withPlugin { engine, path ->
            val first = engine.call(
                "categoryPage",
                "provider" to "Categorised",
                "plugin" to path,
                "category" to "4",
                "filters" to mapOf("region" to "韩国", "sort" to "0", "year" to "", "genre" to null),
                "query" to "love",
            )
            val items = first["items"] as List<Map<String, Any?>>
            // Unset filters ("" or null) are left out of what the extension gets.
            assertEquals("4|{\"region\":\"韩国\",\"sort\":\"0\"}|love|1", items.single()["name"])
            assertEquals(mapOf("Referer" to "https://categorised.invalid/"), items.single()["posterHeaders"])
            assertEquals(true, first["hasNext"])

            val last = engine.call("categoryPage", "provider" to "Categorised", "plugin" to path, "category" to "4", "page" to 3)
            assertEquals("4|{}||3", (last["items"] as List<Map<String, Any?>>).single()["name"])
            assertEquals(false, last["hasNext"])
        }
    }

    @Test
    @Suppress("UNCHECKED_CAST")
    fun `an extension without categories says so`() = runBlocking {
        val engine = Engine(TestLoader, { Context() }, "test")
        val file = cs3(UncategorisedPlugin::class.java.name).path
        engine.execute("loadPlugin", Json.mapper.valueToTree(mapOf("path" to file)))
        try {
            val answer = engine.call("categories", "provider" to "Plain", "plugin" to file)
            assertEquals(false, answer["supported"])
            assertTrue((answer["categories"] as List<*>).isEmpty())
            val error = assertFailsWith<UnsupportedOperationException> {
                engine.call("categoryPage", "provider" to "Plain", "plugin" to file, "category" to "1")
            }
            assertEquals("Plain has no categories", error.message)
        } finally {
            engine.execute("unloadPlugin", Json.mapper.valueToTree(mapOf("path" to file)))
        }
        Unit
    }

    @Test
    fun `an extension's failure is the call's`() = runBlocking {
        withPlugin { engine, path ->
            val error = assertFailsWith<Exception> {
                engine.call("categoryPage", "provider" to "Categorised", "plugin" to path, "category" to "broken")
            }
            assertEquals("site down", Json.rootCause(error).message)
        }
    }
}

class CategorisedPlugin : Plugin() {
    override fun load(context: Context) {
        registerMainAPI(CategorisedApi())
    }
}

class UncategorisedPlugin : Plugin() {
    override fun load(context: Context) {
        registerMainAPI(UncategorisedApi())
    }
}

class UncategorisedApi : MainAPI() {
    override var name = "Plain"
    override var mainUrl = "https://plain.invalid"
}

/** Two categories; every category has three pages of one title, named for what was asked. */
class CategorisedApi : MainAPI() {
    override var name = "Categorised"
    override var mainUrl = "https://categorised.invalid"

    fun csCategories(): String = """
        [
          {"id": 3, "name": "电影",
           "filters": [
             {"key": "region", "name": "地区", "options": [{"value": "韩国"}, {"value": "日本", "label": "Japan"}]},
             {"key": "empty", "name": "Nothing", "options": []}
           ],
           "sorts": [{"value": "2", "label": "热播"}, {"value": "0", "label": "最新"}]},
          {"id": "4", "name": "电视剧"},
          {"id": "5"}
        ]
    """

    fun csCategoryPage(categoryId: String, filtersJson: String, query: String, page: Int): SearchResponseList = runBlocking {
        if (categoryId == "broken") throw IllegalStateException("site down")
        val item = newMovieSearchResponse("$categoryId|$filtersJson|$query|$page", "$mainUrl/$categoryId/$page", TvType.Movie) {
            posterUrl = "$mainUrl/poster.jpg"
            posterHeaders = mapOf("Referer" to "$mainUrl/")
        }
        newSearchResponseList(listOf(item), hasNext = page < 3)
    }
}
