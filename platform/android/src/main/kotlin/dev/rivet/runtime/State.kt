package dev.rivet.runtime

data class RivetStateChange(
    val name: String,
    val value: RivetValue,
)

suspend fun RivetClient.getState(name: String): RivetValue =
    call("\$state/get", listOf(RivetValue.StringValue(name)))

suspend fun RivetClient.setState(name: String, value: RivetValue): RivetValue =
    call("\$state/set", listOf(RivetValue.StringValue(name), value))

fun stateChange(eventName: String, value: RivetValue): RivetStateChange? {
    if (eventName != "\$state") return null
    val fields = (value as? RivetValue.ListValue)?.values ?: return null
    if (fields.size != 2) return null
    val name = (fields[0] as? RivetValue.StringValue)?.value ?: return null
    return RivetStateChange(name, fields[1])
}
