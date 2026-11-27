package dev.akash.cs3engine

import com.fasterxml.jackson.databind.JsonNode
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.SearchResponse
import com.lagradost.cloudstream3.SearchResponseList
import java.lang.reflect.Method

/**
 * A provider's categories, for the app's own category screens. CloudStream has no such API, so an extension
 * opts in with two public, non-suspending methods on its `MainAPI`, found here by name:
 *
 *     fun csCategories(): String
 *         JSON: [{id, name, filters: [{key, name, options: [{value, label}]}], sorts: [{value, label}]}]
 *         Options leave out "all": a filter left unset means all. The first sort is the default.
 *
 *     fun csCategoryPage(categoryId: String, filtersJson: String, query: String, page: Int): SearchResponseList
 *         One page (1-based) of a category's titles. filtersJson is an object of the chosen options,
 *         {"<filter key>": "<option value>", "sort": "<sort value>"}, with unset ones left out; query searches
 *         within the category ("" for none). It may block: the engine calls it off the main thread, with a
 *         timeout, so an extension can wrap its suspending code in runBlocking.
 *
 * The items are mapped like search results ([Mappers.searchItem]), so posters and their headers come through
 * the same. While this engine runs, the system property [PROPERTY] is "true": an extension can leave out its own
 * ways into its categories where the app shows them.
 */
internal object CategoryCalls {
    const val PROPERTY = "cs3engine.categories"
    private const val CATEGORIES = "csCategories"
    private const val PAGE = "csCategoryPage"

    /** {supported, categories}: supported is false, with no categories, for an extension without them. */
    fun categories(api: MainAPI): Map<String, Any?> {
        val method = method(api, CATEGORIES) ?: return mapOf("supported" to false, "categories" to emptyList<Any>())
        val raw = method.invoke(api) as? String ?: return mapOf("supported" to true, "categories" to emptyList<Any>())
        return mapOf("supported" to true, "categories" to parseCategories(raw))
    }

    /** {items, hasNext}; an extension without categories is an error. */
    fun page(api: MainAPI, category: String, filters: JsonNode, query: String, page: Int): Map<String, Any?> {
        val method = method(api, PAGE, String::class.java, String::class.java, String::class.java, Int::class.javaPrimitiveType!!)
            ?: throw UnsupportedOperationException("${api.name} has no categories")
        val chosen = Json.mapper.createObjectNode()
        filters.fields().forEach { (key, value) ->
            if (value.isValueNode && !value.isNull && value.asText().isNotEmpty()) chosen.put(key, value.asText())
        }
        val result = method.invoke(api, category, Json.mapper.writeValueAsString(chosen), query, page.coerceAtLeast(1))
        val (items, hasNext) = when (result) {
            is SearchResponseList -> result.items to result.hasNext
            is List<*> -> result to false
            null -> emptyList<Any>() to false
            else -> throw IllegalStateException("${api.name}'s $PAGE returned ${result.javaClass.name}, not a SearchResponseList")
        }
        return mapOf("items" to items.filterIsInstance<SearchResponse>().map(Mappers::searchItem), "hasNext" to hasNext)
    }

    private fun method(api: MainAPI, name: String, vararg types: Class<*>): Method? =
        try {
            api.javaClass.getMethod(name, *types)
        } catch (_: NoSuchMethodException) {
            null
        }

    /** The extension's JSON, kept to the contract's shape: entries without an id or a name are dropped. */
    fun parseCategories(raw: String): List<Map<String, Any?>> {
        val root = Json.mapper.readTree(raw)
        val list = if (root.isArray) root else root.path("categories")
        return list.mapNotNull { node ->
            val id = node.path("id").scalar() ?: return@mapNotNull null
            val name = node.path("name").scalar() ?: return@mapNotNull null
            mapOf(
                "id" to id,
                "name" to name,
                "filters" to node.path("filters").mapNotNull { filter ->
                    val key = filter.path("key").scalar() ?: return@mapNotNull null
                    val options = options(filter.path("options"))
                    if (options.isEmpty()) null else mapOf("key" to key, "name" to (filter.path("name").scalar() ?: key), "options" to options)
                },
                "sorts" to options(node.path("sorts")),
            )
        }
    }

    private fun options(list: JsonNode): List<Map<String, String>> = list.mapNotNull { option ->
        val value = option.path("value").scalar() ?: return@mapNotNull null
        mapOf("value" to value, "label" to (option.path("label").scalar() ?: value))
    }

    private fun JsonNode.scalar(): String? = takeIf { it.isValueNode && !it.isNull }?.asText()?.trim()?.ifEmpty { null }
}
