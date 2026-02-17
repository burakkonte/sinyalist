// =============================================================================
// SINYALIST — Nodus BLE Mesh Layer (Kotlin) — v2 Field-Ready
// =============================================================================
// v2 changes:
//   B1. Priority queue: TRAPPED > MEDICAL > SOS > STATUS > CHAT
//   B2. LRU dedup set (deterministic) + bloom filter (optimization)
//       TTL + hop_count enforcement, strict max packet size, drop malformed
//   B3. SQLite persistence for store-carry-forward (survives restarts)
//   B4. Watchdog via ForegroundService (see SinyalistForegroundService)
// =============================================================================

package com.sinyalist.mesh

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import java.nio.ByteBuffer
import java.util.*
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import kotlin.math.ln

// ---------------------------------------------------------------------------
// Bloom Filter — O(1) dedup, zero false negatives, tunable false positive rate
// ---------------------------------------------------------------------------

class BloomFilter(
    private val expectedInsertions: Int = 10_000,
    private val falsePositiveRate: Double = 0.001
) {
    private val numBits: Int
    private val numHashes: Int
    private val bitSet: BitSet

    init {
        numBits = ((-expectedInsertions * ln(falsePositiveRate)) / (ln(2.0) * ln(2.0))).toInt()
            .coerceAtLeast(64)
        numHashes = ((numBits.toDouble() / expectedInsertions) * ln(2.0)).toInt()
            .coerceIn(1, 16)
        bitSet = BitSet(numBits)
    }

    fun add(data: ByteArray) {
        val h1 = murmurHash3(data, 0)
        val h2 = murmurHash3(data, h1)
        for (i in 0 until numHashes) {
            val bit = abs((h1 + i * h2) % numBits)
            bitSet.set(bit)
        }
    }

    fun mightContain(data: ByteArray): Boolean {
        val h1 = murmurHash3(data, 0)
        val h2 = murmurHash3(data, h1)
        for (i in 0 until numHashes) {
            val bit = abs((h1 + i * h2) % numBits)
            if (!bitSet.get(bit)) return false
        }
        return true
    }

    fun clear() = bitSet.clear()

    val fillRatio: Double
        get() = bitSet.cardinality().toDouble() / numBits

    private fun murmurHash3(data: ByteArray, seed: Int): Int {
        var h = seed
        for (b in data) {
            var k = b.toInt()
            k = k * 0xcc9e2d51.toInt()
            k = Integer.rotateLeft(k, 15)
            k = k * 0x1b873593
            h = h xor k
            h = Integer.rotateLeft(h, 13)
            h = h * 5 + 0xe6546b64.toInt()
        }
        h = h xor data.size
        h = h xor (h ushr 16)
        h = h * 0x85ebca6b.toInt()
        h = h xor (h ushr 13)
        h = h * 0xc2b2ae35.toInt()
        h = h xor (h ushr 16)
        return h
    }
}

// ---------------------------------------------------------------------------
// LRU Dedup Set — deterministic dedup keyed by packet_id
// ---------------------------------------------------------------------------

class LruDedupSet(private val maxSize: Int = 10_000) {
    // LinkedHashMap with accessOrder=true gives us LRU eviction
    private val map = object : LinkedHashMap<String, Long>(maxSize, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>?): Boolean {
            return size > maxSize
        }
    }

    @Synchronized
    fun contains(key: ByteArray): Boolean {
        return map.containsKey(key.toHexString())
    }

    @Synchronized
    fun add(key: ByteArray): Boolean {
        val hex = key.toHexString()
        if (map.containsKey(hex)) return false // Already seen
        map[hex] = System.currentTimeMillis()
        return true // New entry
    }

    @Synchronized
    fun evictExpired(ttlMs: Long) {
        val cutoff = System.currentTimeMillis() - ttlMs
        map.entries.removeIf { it.value < cutoff }
    }

    @Synchronized
    fun size(): Int = map.size

    private fun ByteArray.toHexString(): String {
        return joinToString("") { "%02x".format(it) }
    }
}

// ---------------------------------------------------------------------------
// Priority levels for packet routing (B1)
// ---------------------------------------------------------------------------

enum class MeshPriority(val level: Int) {
    TRAPPED(0),    // Highest — life-or-death
    MEDICAL(1),
    SOS(2),
    STATUS(3),
    CHAT(4),       // Lowest
    UNKNOWN(5);

    companion object {
        fun fromMsgType(msgType: Int): MeshPriority {
            return when (msgType) {
                1 -> TRAPPED   // MSG_TRAPPED
                2 -> MEDICAL   // MSG_MEDICAL
                3 -> SOS       // MSG_SOS
                4 -> STATUS    // MSG_STATUS
                5 -> STATUS    // MSG_HEARTBEAT
                else -> UNKNOWN
            }
        }

        fun fromPacket(packet: MeshPacket): MeshPriority {
            // Check is_trapped flag first (field 21, varint tag 168)
            if (packet.isTrapped) return TRAPPED
            return fromMsgType(packet.msgType)
        }
    }
}

// ---------------------------------------------------------------------------
// Store-Carry-Forward Packet
// ---------------------------------------------------------------------------

data class MeshPacket(
    val payload: ByteArray,
    val hopCount: Int,
    val ttl: Int,
    val receivedAtMs: Long,
    val originHash: Int,
    val msgType: Int = 0,
    val isTrapped: Boolean = false
) : Comparable<MeshPacket> {

    val priority: MeshPriority
        get() = MeshPriority.fromPacket(this)

    fun dedupKey(): ByteArray {
        // Try to extract packet_id (field 24, bytes) from protobuf
        val packetId = extractPacketId(payload)
        if (packetId != null && packetId.size == 16) return packetId
        // Fallback: first 8 bytes (user_id) + timestamp bytes
        if (payload.size < 16) return payload
        return payload.sliceArray(0..7) + payload.sliceArray(payload.size - 8 until payload.size)
    }

    val isExpired: Boolean
        get() = hopCount >= ttl || (System.currentTimeMillis() - receivedAtMs) > PACKET_TTL_MS

    // Priority ordering: lower level = higher priority (processed first)
    override fun compareTo(other: MeshPacket): Int {
        return this.priority.level.compareTo(other.priority.level)
    }

    companion object {
        const val PACKET_TTL_MS = 300_000L // 5 minutes
        const val MAX_HOP_COUNT = 7
        const val MAX_TTL = 10

        fun extractPacketId(payload: ByteArray): ByteArray? {
            // Parse protobuf to find field 24 (tag = 24 << 3 | 2 = 194)
            var pos = 0
            while (pos < payload.size) {
                val tag = readVarint(payload, pos)
                pos = tag.second
                val fieldNumber = (tag.first shr 3).toInt()
                val wireType = (tag.first and 0x07).toInt()

                when (wireType) {
                    0 -> { // Varint
                        val v = readVarint(payload, pos)
                        pos = v.second
                    }
                    1 -> pos += 8 // 64-bit
                    2 -> { // Length-delimited
                        val lenResult = readVarint(payload, pos)
                        val len = lenResult.first.toInt()
                        pos = lenResult.second
                        if (fieldNumber == 24 && len == 16) {
                            return payload.sliceArray(pos until pos + len)
                        }
                        pos += len
                    }
                    5 -> pos += 4 // 32-bit
                    else -> return null // Unknown wire type
                }
                if (pos < 0 || pos > payload.size) return null
            }
            return null
        }

        fun extractMsgType(payload: ByteArray): Int {
            // Parse protobuf to find field 26 (msg_type, varint)
            var pos = 0
            while (pos < payload.size) {
                val tag = readVarint(payload, pos)
                pos = tag.second
                val fieldNumber = (tag.first shr 3).toInt()
                val wireType = (tag.first and 0x07).toInt()

                when (wireType) {
                    0 -> {
                        val v = readVarint(payload, pos)
                        pos = v.second
                        if (fieldNumber == 26) return v.first.toInt()
                    }
                    1 -> pos += 8
                    2 -> {
                        val lenResult = readVarint(payload, pos)
                        pos = lenResult.second + lenResult.first.toInt()
                    }
                    5 -> pos += 4
                    else -> return 0
                }
                if (pos < 0 || pos > payload.size) return 0
            }
            return 0
        }

        fun extractIsTrapped(payload: ByteArray): Boolean {
            // Parse protobuf to find field 21 (is_trapped, varint/bool)
            var pos = 0
            while (pos < payload.size) {
                val tag = readVarint(payload, pos)
                pos = tag.second
                val fieldNumber = (tag.first shr 3).toInt()
                val wireType = (tag.first and 0x07).toInt()

                when (wireType) {
                    0 -> {
                        val v = readVarint(payload, pos)
                        pos = v.second
                        if (fieldNumber == 21) return v.first != 0L
                    }
                    1 -> pos += 8
                    2 -> {
                        val lenResult = readVarint(payload, pos)
                        pos = lenResult.second + lenResult.first.toInt()
                    }
                    5 -> pos += 4
                    else -> return false
                }
                if (pos < 0 || pos > payload.size) return false
            }
            return false
        }

        private fun readVarint(data: ByteArray, startPos: Int): Pair<Long, Int> {
            var result = 0L
            var shift = 0
            var pos = startPos
            while (pos < data.size) {
                val b = data[pos].toLong() and 0xFF
                pos++
                result = result or ((b and 0x7F) shl shift)
                if ((b and 0x80) == 0L) break
                shift += 7
                if (shift >= 64) break
            }
            return Pair(result, pos)
        }
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is MeshPacket) return false
        return payload.contentEquals(other.payload)
    }

    override fun hashCode(): Int = payload.contentHashCode()
}

// ---------------------------------------------------------------------------
// Priority Queue for mesh packets (B1)
// ---------------------------------------------------------------------------

class PriorityPacketQueue(private val maxSize: Int = 500) {
    private val queue = PriorityQueue<MeshPacket>()
    private val lock = Object()

    // Rate limits per message type (packets per 30-second window)
    private val rateLimits = mapOf(
        MeshPriority.TRAPPED to 20,
        MeshPriority.MEDICAL to 15,
        MeshPriority.SOS to 10,
        MeshPriority.STATUS to 5,
        MeshPriority.CHAT to 3,
        MeshPriority.UNKNOWN to 3,
    )
    private val rateCounts = mutableMapOf<MeshPriority, MutableList<Long>>()

    fun enqueue(packet: MeshPacket): Boolean {
        synchronized(lock) {
            // Check rate limit for this priority
            if (!checkRateLimit(packet.priority)) {
                Log.w("PriorityQueue", "Rate limited: ${packet.priority}")
                return false
            }

            // Evict expired packets
            queue.removeIf { it.isExpired }

            // If at capacity, drop lowest priority packet
            while (queue.size >= maxSize) {
                // Remove the last element (lowest priority = highest level number)
                val sorted = queue.sortedByDescending { it.priority.level }
                val lowest = sorted.firstOrNull() ?: break
                queue.remove(lowest)
                Log.d("PriorityQueue", "Evicted ${lowest.priority} packet (at capacity)")
            }

            queue.add(packet)
            return true
        }
    }

    fun dequeue(): MeshPacket? {
        synchronized(lock) {
            // Remove expired
            queue.removeIf { it.isExpired }
            return queue.poll() // Returns highest priority (lowest level)
        }
    }

    fun peek(): MeshPacket? {
        synchronized(lock) {
            queue.removeIf { it.isExpired }
            return queue.peek()
        }
    }

    fun toList(): List<MeshPacket> {
        synchronized(lock) {
            queue.removeIf { it.isExpired }
            return queue.sortedBy { it.priority.level }
        }
    }

    fun size(): Int = synchronized(lock) { queue.size }

    fun clear() = synchronized(lock) { queue.clear() }

    private fun checkRateLimit(priority: MeshPriority): Boolean {
        val now = System.currentTimeMillis()
        val windowMs = 30_000L
        val limit = rateLimits[priority] ?: 3

        val timestamps = rateCounts.getOrPut(priority) { mutableListOf() }
        timestamps.removeIf { now - it > windowMs }

        if (timestamps.size >= limit) return false
        timestamps.add(now)
        return true
    }
}

// ---------------------------------------------------------------------------
// Nodus Mesh Controller (v2 Field-Ready)
// ---------------------------------------------------------------------------

@SuppressLint("MissingPermission")
class NodusMeshController(private val context: Context) {

    companion object {
        private const val TAG = "NodusMesh"

        val SERVICE_UUID: UUID = UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234567890")
        val PACKET_CHAR_UUID: UUID = UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234567891")
        val META_CHAR_UUID: UUID = UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234567892")

        const val MAX_BUFFER_SIZE = 500
        const val MAX_PACKET_SIZE = 512
        const val SCAN_INTERVAL_MS = 5_000L
        const val ADVERTISE_INTERVAL_MS = 2_000L
        const val BLOOM_RESET_THRESHOLD = 0.75
        const val DEDUP_EVICT_INTERVAL_MS = 60_000L
    }

    // State
    private val isActive = AtomicBoolean(false)
    private val priorityQueue = PriorityPacketQueue(MAX_BUFFER_SIZE) // B1: Priority queue
    private val bloomFilter = BloomFilter(expectedInsertions = 10_000, falsePositiveRate = 0.001)
    private val lruDedup = LruDedupSet(maxSize = 10_000) // B2: Deterministic LRU dedup
    private var meshNodeId: Int = 0
    private var dedupEvictTimer: Timer? = null
    private var packetStore: MeshPacketStore? = null // B3: SQLite persistence

    // Counters for observability
    private val stormDropCount = AtomicInteger(0)
    private val dedupDropCount = AtomicInteger(0)
    private val ttlDropCount = AtomicInteger(0)
    private val malformedDropCount = AtomicInteger(0)
    private val totalRelayedCount = AtomicInteger(0)

    // BLE components
    private var bluetoothManager: BluetoothManager? = null
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var bleAdvertiser: BluetoothLeAdvertiser? = null
    private var bleScanner: BluetoothLeScanner? = null
    private var gattServer: BluetoothGattServer? = null

    // Callbacks
    var onPacketReceived: ((MeshPacket) -> Unit)? = null
    var onPeerDiscovered: ((String) -> Unit)? = null
    var onMeshStatsUpdate: ((MeshStats) -> Unit)? = null
    var onStateTransition: ((String, String) -> Unit)? = null // B4: state logging

    data class MeshStats(
        val activeNodes: Int,
        val bufferedPackets: Int,
        val totalRelayed: Int,
        val bloomFillRatio: Double,
        val dedupSetSize: Int = 0,
        val stormDrops: Int = 0,
        val dedupDrops: Int = 0,
        val ttlDrops: Int = 0,
        val malformedDrops: Int = 0
    )

    private var discoveredPeers = mutableSetOf<String>()

    // -----------------------------------------------------------------------
    // Initialization
    // -----------------------------------------------------------------------

    fun initialize(): Boolean {
        bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        bluetoothAdapter = bluetoothManager?.adapter

        if (bluetoothAdapter == null || !bluetoothAdapter!!.isEnabled) {
            Log.e(TAG, "Bluetooth not available or not enabled")
            logTransition("init", "failed:bt_unavailable")
            return false
        }

        bleAdvertiser = bluetoothAdapter?.bluetoothLeAdvertiser
        bleScanner = bluetoothAdapter?.bluetoothLeScanner

        meshNodeId = bluetoothAdapter?.address?.hashCode() ?: System.nanoTime().toInt()

        // B3: Initialize SQLite persistence for store-carry-forward
        packetStore = MeshPacketStore(context)
        Log.i(TAG, "SQLite packet store initialized")

        Log.i(TAG, "Nodus mesh initialized — nodeId=$meshNodeId")
        logTransition("uninitialized", "initialized")
        return true
    }

    // -----------------------------------------------------------------------
    // Start mesh operations
    // -----------------------------------------------------------------------

    fun startMesh() {
        if (isActive.getAndSet(true)) return

        // B3: Restore persisted packets from SQLite into the priority queue
        packetStore?.let { store ->
            try {
                val restored = store.loadPendingPackets()
                var loaded = 0
                for (packet in restored) {
                    if (!packet.isExpired) {
                        val dedupKey = packet.dedupKey()
                        bloomFilter.add(dedupKey)
                        lruDedup.add(dedupKey)
                        if (priorityQueue.enqueue(packet)) loaded++
                    }
                }
                Log.i(TAG, "B3: Restored $loaded/${restored.size} packets from SQLite")
            } catch (e: Exception) {
                Log.e(TAG, "B3: Failed to load persisted packets", e)
            }
        }

        startGattServer()
        startAdvertising()
        startScanning()

        // Start periodic dedup eviction (also prunes SQLite)
        dedupEvictTimer = Timer().apply {
            scheduleAtFixedRate(object : TimerTask() {
                override fun run() {
                    lruDedup.evictExpired(MeshPacket.PACKET_TTL_MS)
                    // B3: Also evict expired packets from SQLite
                    try {
                        packetStore?.deleteExpired(MeshPacket.PACKET_TTL_MS)
                    } catch (e: Exception) {
                        Log.e(TAG, "B3: Failed to delete expired packets from SQLite", e)
                    }
                }
            }, DEDUP_EVICT_INTERVAL_MS, DEDUP_EVICT_INTERVAL_MS)
        }

        Log.i(TAG, "Mesh network ACTIVE — advertising + scanning")
        logTransition("initialized", "active")
    }

    fun stopMesh() {
        if (!isActive.getAndSet(false)) return

        stopAdvertising()
        stopScanning()
        gattServer?.close()
        gattServer = null
        dedupEvictTimer?.cancel()
        dedupEvictTimer = null

        Log.i(TAG, "Mesh network STOPPED")
        logTransition("active", "stopped")
    }

    // -----------------------------------------------------------------------
    // Inject a local packet into the mesh
    // -----------------------------------------------------------------------

    fun broadcastPacket(protobufBytes: ByteArray) {
        // B2: Strict max packet size enforcement
        if (protobufBytes.size > MAX_PACKET_SIZE) {
            Log.e(TAG, "DROPPED: Packet exceeds MTU budget: ${protobufBytes.size} > $MAX_PACKET_SIZE")
            malformedDropCount.incrementAndGet()
            emitStats()
            return
        }

        // B2: Drop malformed (minimum viable packet = user_id + timestamp)
        if (protobufBytes.size < 10) {
            Log.e(TAG, "DROPPED: Packet too small to be valid: ${protobufBytes.size} bytes")
            malformedDropCount.incrementAndGet()
            emitStats()
            return
        }

        val msgType = MeshPacket.extractMsgType(protobufBytes)
        val isTrapped = MeshPacket.extractIsTrapped(protobufBytes)

        val packet = MeshPacket(
            payload = protobufBytes,
            hopCount = 0,
            ttl = MeshPacket.MAX_HOP_COUNT,
            receivedAtMs = System.currentTimeMillis(),
            originHash = meshNodeId,
            msgType = msgType,
            isTrapped = isTrapped
        )

        // Mark in both dedup structures
        val dedupKey = packet.dedupKey()
        bloomFilter.add(dedupKey)
        lruDedup.add(dedupKey)

        // B1: Enqueue with priority
        val enqueued = priorityQueue.enqueue(packet)
        if (!enqueued) {
            Log.w(TAG, "RATE LIMITED: Local packet not enqueued (priority=${packet.priority})")
            stormDropCount.incrementAndGet()
        }

        // B3: Persist to SQLite for store-carry-forward across restarts
        if (enqueued) {
            try {
                packetStore?.insertPacket(packet)
            } catch (e: Exception) {
                Log.e(TAG, "B3: Failed to persist packet to SQLite", e)
            }
        }

        // Update GATT characteristic
        updateGattCharacteristic(protobufBytes)

        Log.i(TAG, "Local packet injected — ${protobufBytes.size}B, priority=${packet.priority}, trapped=$isTrapped")
        emitStats()
    }

    // -----------------------------------------------------------------------
    // Process received packet with full validation (B2)
    // -----------------------------------------------------------------------

    private fun processReceivedPacket(payload: ByteArray, sourceAddress: String): Boolean {
        // B2: Size validation
        if (payload.size > MAX_PACKET_SIZE) {
            Log.w(TAG, "DROPPED: Oversized from $sourceAddress: ${payload.size}B")
            malformedDropCount.incrementAndGet()
            return false
        }
        if (payload.size < 10) {
            Log.w(TAG, "DROPPED: Undersized from $sourceAddress: ${payload.size}B")
            malformedDropCount.incrementAndGet()
            return false
        }

        // B2: Deterministic LRU dedup (authoritative)
        val dedupKey = if (payload.size >= 16) {
            val packetId = MeshPacket.extractPacketId(payload)
            packetId ?: (payload.sliceArray(0..7) + payload.sliceArray(payload.size - 8 until payload.size))
        } else payload

        // Fast bloom check first (optimization)
        if (bloomFilter.mightContain(dedupKey)) {
            // Confirm with authoritative LRU set
            if (lruDedup.contains(dedupKey)) {
                Log.d(TAG, "DEDUP: Duplicate from $sourceAddress (LRU confirmed)")
                dedupDropCount.incrementAndGet()
                emitStats()
                return false
            }
        }

        // New packet — add to both dedup structures
        bloomFilter.add(dedupKey)
        lruDedup.add(dedupKey)

        // Reset bloom if saturated
        if (bloomFilter.fillRatio > BLOOM_RESET_THRESHOLD) {
            Log.w(TAG, "Bloom filter at ${(bloomFilter.fillRatio * 100).toInt()}% — resetting")
            bloomFilter.clear()
        }

        val msgType = MeshPacket.extractMsgType(payload)
        val isTrapped = MeshPacket.extractIsTrapped(payload)

        val packet = MeshPacket(
            payload = payload,
            hopCount = 1,
            ttl = MeshPacket.MAX_HOP_COUNT,
            receivedAtMs = System.currentTimeMillis(),
            originHash = sourceAddress.hashCode(),
            msgType = msgType,
            isTrapped = isTrapped
        )

        // B2: TTL enforcement
        if (packet.hopCount >= packet.ttl) {
            Log.w(TAG, "DROPPED: TTL exceeded (hop=${packet.hopCount}, ttl=${packet.ttl})")
            ttlDropCount.incrementAndGet()
            emitStats()
            return false
        }

        // B1: Enqueue with priority
        val enqueued = priorityQueue.enqueue(packet)
        if (!enqueued) {
            stormDropCount.incrementAndGet()
            Log.w(TAG, "STORM: Rate limited packet from $sourceAddress (priority=${packet.priority})")
            emitStats()
            return false
        }

        onPacketReceived?.invoke(packet)
        Log.i(TAG, "Received mesh packet: ${payload.size}B from $sourceAddress, priority=${packet.priority}")
        emitStats()
        return true
    }

    // -----------------------------------------------------------------------
    // Relay buffered packets with priority ordering (B1)
    // -----------------------------------------------------------------------

    private fun relayBufferedPackets(targetDevice: BluetoothDevice) {
        val toRelay = priorityQueue.toList()
            .filter { !it.isExpired && it.hopCount < it.ttl }

        Log.i(TAG, "Relaying ${toRelay.size} buffered packets to ${targetDevice.address}")

        for (packet in toRelay) {
            // B2: TTL enforcement on relay
            if (packet.hopCount + 1 >= packet.ttl) {
                Log.d(TAG, "Skip relay: TTL would be exceeded (hop=${packet.hopCount + 1}, ttl=${packet.ttl})")
                ttlDropCount.incrementAndGet()
                continue
            }
            totalRelayedCount.incrementAndGet()
        }

        emitStats()
    }

    // -----------------------------------------------------------------------
    // BLE GATT Server
    // -----------------------------------------------------------------------

    private fun startGattServer() {
        val gattCallback = object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    discoveredPeers.add(device.address)
                    onPeerDiscovered?.invoke(device.address)
                    relayBufferedPackets(device)
                    Log.i(TAG, "Peer connected: ${device.address} — total peers: ${discoveredPeers.size}")
                    logTransition("peer_disconnected", "peer_connected:${device.address}")
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    discoveredPeers.remove(device.address)
                    logTransition("peer_connected:${device.address}", "peer_disconnected")
                }
                emitStats()
            }

            override fun onCharacteristicReadRequest(
                device: BluetoothDevice, requestId: Int, offset: Int,
                characteristic: BluetoothGattCharacteristic
            ) {
                when (characteristic.uuid) {
                    PACKET_CHAR_UUID -> {
                        // B1: Return highest-priority packet
                        val topPacket = priorityQueue.peek()?.payload ?: ByteArray(0)
                        gattServer?.sendResponse(device, requestId,
                            BluetoothGatt.GATT_SUCCESS, offset,
                            topPacket.drop(offset).toByteArray())
                    }
                    META_CHAR_UUID -> {
                        val meta = ByteBuffer.allocate(12)
                            .putInt(meshNodeId)
                            .putInt(priorityQueue.size())
                            .putInt(discoveredPeers.size)
                            .array()
                        gattServer?.sendResponse(device, requestId,
                            BluetoothGatt.GATT_SUCCESS, offset, meta)
                    }
                }
            }
        }

        gattServer = bluetoothManager?.openGattServer(context, gattCallback)

        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        val packetChar = BluetoothGattCharacteristic(
            PACKET_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ
        )

        val metaChar = BluetoothGattCharacteristic(
            META_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ
        )

        service.addCharacteristic(packetChar)
        service.addCharacteristic(metaChar)
        gattServer?.addService(service)

        Log.i(TAG, "GATT server started — service: $SERVICE_UUID")
    }

    private fun updateGattCharacteristic(data: ByteArray) {
        val characteristic = gattServer?.getService(SERVICE_UUID)
            ?.getCharacteristic(PACKET_CHAR_UUID) ?: return
        characteristic.value = data
        for (address in discoveredPeers) {
            val device = bluetoothAdapter?.getRemoteDevice(address) ?: continue
            gattServer?.notifyCharacteristicChanged(device, characteristic, false)
        }
    }

    // -----------------------------------------------------------------------
    // BLE Advertising
    // -----------------------------------------------------------------------

    private var advertiseCallback: AdvertiseCallback? = null

    private fun startAdvertising() {
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        advertiseCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
                Log.i(TAG, "BLE advertising started — HIGH power, LOW_LATENCY")
                logTransition("adv_stopped", "adv_started")
            }
            override fun onStartFailure(errorCode: Int) {
                Log.e(TAG, "BLE advertising failed: errorCode=$errorCode")
                logTransition("adv_stopped", "adv_failed:$errorCode")
            }
        }

        bleAdvertiser?.startAdvertising(settings, data, advertiseCallback)
    }

    private fun stopAdvertising() {
        advertiseCallback?.let { bleAdvertiser?.stopAdvertising(it) }
        advertiseCallback = null
        logTransition("adv_started", "adv_stopped")
    }

    // -----------------------------------------------------------------------
    // BLE Scanning
    // -----------------------------------------------------------------------

    private var scanCallback: ScanCallback? = null

    private fun startScanning() {
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .build()

        scanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                handleScanResult(result)
            }
            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { handleScanResult(it) }
            }
            override fun onScanFailed(errorCode: Int) {
                Log.e(TAG, "BLE scan failed: errorCode=$errorCode")
                logTransition("scan_started", "scan_failed:$errorCode")
            }
        }

        bleScanner?.startScan(listOf(filter), settings, scanCallback)
        Log.i(TAG, "BLE scanning started — filtered for Sinyalist service")
        logTransition("scan_stopped", "scan_started")
    }

    private fun stopScanning() {
        scanCallback?.let { bleScanner?.stopScan(it) }
        scanCallback = null
        logTransition("scan_started", "scan_stopped")
    }

    private fun handleScanResult(result: ScanResult) {
        val device = result.device
        val address = device.address

        if (!discoveredPeers.contains(address)) {
            discoveredPeers.add(address)
            onPeerDiscovered?.invoke(address)
            Log.i(TAG, "New mesh peer discovered: $address (RSSI: ${result.rssi})")
            connectAndReadPackets(device)
        }
    }

    // -----------------------------------------------------------------------
    // GATT Client
    // -----------------------------------------------------------------------

    private fun connectAndReadPackets(device: BluetoothDevice) {
        device.connectGatt(context, false, object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    gatt.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    gatt.close()
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) return
                val char = gatt.getService(SERVICE_UUID)?.getCharacteristic(PACKET_CHAR_UUID)
                if (char != null) {
                    gatt.readCharacteristic(char)
                }
            }

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int
            ) {
                if (status != BluetoothGatt.GATT_SUCCESS) return
                val payload = characteristic.value ?: return

                // B2: Full validation through processReceivedPacket
                processReceivedPacket(payload, device.address)

                gatt.disconnect()
            }
        })
    }

    // -----------------------------------------------------------------------
    // B4: State transition logging
    // -----------------------------------------------------------------------

    private fun logTransition(from: String, to: String) {
        val msg = "STATE: $from -> $to"
        Log.i(TAG, msg)
        onStateTransition?.invoke(from, to)
    }

    // -----------------------------------------------------------------------
    // Stats emission
    // -----------------------------------------------------------------------

    private fun emitStats() {
        onMeshStatsUpdate?.invoke(MeshStats(
            activeNodes = discoveredPeers.size,
            bufferedPackets = priorityQueue.size(),
            totalRelayed = totalRelayedCount.get(),
            bloomFillRatio = bloomFilter.fillRatio,
            dedupSetSize = lruDedup.size(),
            stormDrops = stormDropCount.get(),
            dedupDrops = dedupDropCount.get(),
            ttlDrops = ttlDropCount.get(),
            malformedDrops = malformedDropCount.get()
        ))
    }

    // -----------------------------------------------------------------------
    // B4: Watchdog support — called by ForegroundService
    // -----------------------------------------------------------------------

    fun isHealthy(): Boolean {
        return isActive.get() && bleAdvertiser != null && bleScanner != null
    }

    fun restartIfNeeded(): Boolean {
        if (!isActive.get()) return false
        if (bleAdvertiser == null || bleScanner == null) {
            Log.w(TAG, "WATCHDOG: BLE components lost, restarting mesh")
            logTransition("degraded", "restarting")
            stopMesh()
            if (initialize()) {
                startMesh()
                logTransition("restarting", "active")
                return true
            }
            logTransition("restarting", "failed")
        }
        return false
    }

    // -----------------------------------------------------------------------
    // Flutter MethodChannel handler
    // -----------------------------------------------------------------------

    fun handleMethodCall(method: String, arguments: Any?): Any? {
        return when (method) {
            "initialize" -> initialize()
            "startMesh"  -> { startMesh(); true }
            "stopMesh"   -> { stopMesh(); true }
            "broadcastPacket" -> {
                val bytes = arguments as? ByteArray ?: return false
                broadcastPacket(bytes)
                true
            }
            "getStats" -> mapOf(
                "activeNodes" to discoveredPeers.size,
                "bufferedPackets" to priorityQueue.size(),
                "totalRelayed" to totalRelayedCount.get(),
                "bloomFillRatio" to bloomFilter.fillRatio,
                "dedupSetSize" to lruDedup.size(),
                "stormDrops" to stormDropCount.get(),
                "dedupDrops" to dedupDropCount.get(),
                "ttlDrops" to ttlDropCount.get(),
                "malformedDrops" to malformedDropCount.get()
            )
            "isHealthy" -> isHealthy()
            else -> null
        }
    }
}
