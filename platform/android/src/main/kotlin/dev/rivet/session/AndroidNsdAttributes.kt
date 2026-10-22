package dev.rivet.session

/** Convert Android's unordered, resolved NSD TXT attribute map to Rivet's
 * canonical logical record. The platform decoder owns wire-order/duplicates.
 */
fun deviceDiscoveryTXTFromAttributes(attributes: Map<String, ByteArray>): ByteArray? {
    if (attributes.keys != setOf("id", "pair", "v")) return null
    fun read(key: String): String? {
        val bytes = attributes[key] ?: return null
        if (bytes.isEmpty() || bytes.size > DEVICE_DISCOVERY_MAXIMUM_TXT_RECORD_SIZE) return null
        val value = String(bytes, Charsets.UTF_8)
        return value.takeIf { it.toByteArray(Charsets.UTF_8).contentEquals(bytes) }
    }
    val id = read("id") ?: return null
    val pair = read("pair") ?: return null
    val version = read("v") ?: return null
    if (!validDiscoveryAdvertisementID(id) || (pair != "0" && pair != "1") ||
        version != SESSION_VERSION.toString()) return null
    return encodeDiscoveryTXT(DeviceAdvertisement(id, pair == "1"))
}
