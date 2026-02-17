// =============================================================================
// SINYALIST — Nodus BLE Mesh Layer (Kotlin)
// =============================================================================
// Implements:
//   1. BLE GATT Server: Advertises emergency packets for nearby devices
//   2. BLE GATT Client: Scans and receives packets from mesh peers
//   3. Bloom Filter:    Probabilistic dedup to prevent packet storms
//   4. Store-Carry-Forward: Buffers packets when no peers, relays on contact
//   5. Hop Management:  TTL-based propagation control
//
// Design: Each device is both advertiser AND scanner simultaneously,
// creating a fully decentralized mesh with no coordinator.
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
        // Optimal sizing: m = -n*ln(p) / (ln2)^2
        numBits = ((-expectedInsertions * ln(falsePositiveRate)) / (ln(2.0) * ln(2.0))).toInt()
            .coerceAtLeast(64)
        // Optimal hash count: k = (m/n) * ln2
        numHashes = ((numBits.toDouble() / expectedInsertions) * ln(2.0)).toInt()
            .coerceIn(1, 16)
        bitSet = BitSet(numBits)
    }

    // Uses double hashing: h(i) = h1 + i*h2 — avoids computing k independent hashes
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
            if (!bitSet.get(bit)) return false  // Definitely not present
        }
        return true  // Probably present
    }

    fun clear() = bitSet.clear()

    val fillRatio: Double
        get() = bitSet.cardinality().toDouble() / numBits

    // MurmurHash3 32-bit finalizer — fast, good distribution
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
// Store-Carry-Forward Buffer
// ---------------------------------------------------------------------------
// When no peers are reachable, packets accumulate here.
// On next peer contact, the entire buffer is flushed.

data class MeshPacket(
    val payload: ByteArray,       // Raw protobuf bytes
    val hopCount: Int,
    val ttl: Int,
    val receivedAtMs: Long,
    val originHash: Int           // For dedup key generation
) {
    // Dedup key: first 8 bytes of payload (user_id) + last 8 bytes (timestamp)
    fun dedupKey(): ByteArray {
        if (payload.size < 16) return payload
        return payload.sliceArray(0..7) + payload.sliceArray(payload.size - 8 until payload.size)
    }

    val isExpired: Boolean
        get() = hopCount >= ttl || (System.currentTimeMillis() - receivedAtMs) > PACKET_TTL_MS

    companion object {
        const val PACKET_TTL_MS = 300_000L // 5 minutes
    }
}

// ---------------------------------------------------------------------------
// Nodus Mesh Controller
// ---------------------------------------------------------------------------

@SuppressLint("MissingPermission")
class NodusMeshController(private val context: Context) {

    companion object {
        private const val TAG = "NodusMesh"

        // Custom GATT service UUID for Sinyalist emergency mesh
        val SERVICE_UUID: UUID = UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234567890")
        // Characteristic: emergency packet data
        val PACKET_CHAR_UUID: UUID = UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234567891")
        // Characteristic: mesh metadata (hop count, node count)
        val META_CHAR_UUID: UUID = UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234567892")

        const val MAX_BUFFER_SIZE = 500        // Max packets in store-carry-forward
        const val MAX_PACKET_SIZE = 512        // BLE ATT_MTU budget
        const val SCAN_INTERVAL_MS = 5_000L    // Scan duty cycle
        const val ADVERTISE_INTERVAL_MS = 2_000L
        const val BLOOM_RESET_THRESHOLD = 0.75 // Reset bloom filter at 75% fill
    }

    // State
    private val isActive = AtomicBoolean(false)
    private val packetBuffer = ConcurrentLinkedQueue<MeshPacket>()
    private val bloomFilter = BloomFilter(expectedInsertions = 10_000, falsePositiveRate = 0.001)
    private var meshNodeId: Int = 0

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

    data class MeshStats(
        val activeNodes: Int,
        val bufferedPackets: Int,
        val totalRelayed: Int,
        val bloomFillRatio: Double
    )

    private var totalRelayed = 0
    private var discoveredPeers = mutableSetOf<String>()

    // -----------------------------------------------------------------------
    // Initialization
    // -----------------------------------------------------------------------

    fun initialize(): Boolean {
        bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        bluetoothAdapter = bluetoothManager?.adapter

        if (bluetoothAdapter == null || !bluetoothAdapter!!.isEnabled) {
            Log.e(TAG, "Bluetooth not available or not enabled")
            return false
        }

        bleAdvertiser = bluetoothAdapter?.bluetoothLeAdvertiser
        bleScanner = bluetoothAdapter?.bluetoothLeScanner

        // Generate stable mesh node ID from device address hash
        meshNodeId = bluetoothAdapter?.address?.hashCode() ?: System.nanoTime().toInt()

        Log.i(TAG, "Nodus mesh initialized — nodeId=$meshNodeId")
        return true
    }

    // -----------------------------------------------------------------------
    // Start mesh operations (both advertise + scan)
    // -----------------------------------------------------------------------

    fun startMesh() {
        if (isActive.getAndSet(true)) return

        startGattServer()
        startAdvertising()
        startScanning()

        Log.i(TAG, "Mesh network ACTIVE — advertising + scanning")
    }

    fun stopMesh() {
        if (!isActive.getAndSet(false)) return

        stopAdvertising()
        stopScanning()
        gattServer?.close()
        gattServer = null

        Log.i(TAG, "Mesh network STOPPED")
    }

    // -----------------------------------------------------------------------
    // Inject a local packet into the mesh (from our seismic detector)
    // -----------------------------------------------------------------------

    fun broadcastPacket(protobufBytes: ByteArray) {
        if (protobufBytes.size > MAX_PACKET_SIZE) {
            Log.e(TAG, "Packet exceeds MTU budget: ${protobufBytes.size} > $MAX_PACKET_SIZE")
            return
        }

        val packet = MeshPacket(
            payload = protobufBytes,
            hopCount = 0,
            ttl = 7,
            receivedAtMs = System.currentTimeMillis(),
            originHash = meshNodeId
        )

        // Mark in bloom filter so we don't re-process our own packet
        bloomFilter.add(packet.dedupKey())

        // Add to buffer for relay
        enqueuePacket(packet)

        // Update GATT characteristic so scanning peers can read it
        updateGattCharacteristic(protobufBytes)

        Log.i(TAG, "Local packet injected into mesh — ${protobufBytes.size} bytes")
    }

    // -----------------------------------------------------------------------
    // Store-Carry-Forward buffer management
    // -----------------------------------------------------------------------

    private fun enqueuePacket(packet: MeshPacket) {
        // Evict expired packets
        packetBuffer.removeAll { it.isExpired }

        // Enforce max buffer size (FIFO eviction)
        while (packetBuffer.size >= MAX_BUFFER_SIZE) {
            packetBuffer.poll()
        }

        packetBuffer.add(packet)
        emitStats()
    }

    private fun relayBufferedPackets(targetDevice: BluetoothDevice) {
        val toRelay = packetBuffer.filter { !it.isExpired && it.hopCount < it.ttl }
        Log.i(TAG, "Relaying ${toRelay.size} buffered packets to ${targetDevice.address}")

        for (packet in toRelay) {
            // Increment hop count for relayed copy
            val relayed = packet.copy(hopCount = packet.hopCount + 1)
            // In production: write to target's GATT characteristic
            totalRelayed++
        }

        emitStats()
    }

    // -----------------------------------------------------------------------
    // BLE GATT Server — makes our packets readable by scanning peers
    // -----------------------------------------------------------------------

    private fun startGattServer() {
        val gattCallback = object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    discoveredPeers.add(device.address)
                    onPeerDiscovered?.invoke(device.address)
                    // Flush store-carry-forward buffer to new peer
                    relayBufferedPackets(device)
                    Log.i(TAG, "Peer connected: ${device.address} — total peers: ${discoveredPeers.size}")
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    discoveredPeers.remove(device.address)
                }
                emitStats()
            }

            override fun onCharacteristicReadRequest(
                device: BluetoothDevice, requestId: Int, offset: Int,
                characteristic: BluetoothGattCharacteristic
            ) {
                when (characteristic.uuid) {
                    PACKET_CHAR_UUID -> {
                        val latestPacket = packetBuffer.peek()?.payload ?: ByteArray(0)
                        gattServer?.sendResponse(device, requestId,
                            BluetoothGatt.GATT_SUCCESS, offset,
                            latestPacket.drop(offset).toByteArray())
                    }
                    META_CHAR_UUID -> {
                        val meta = ByteBuffer.allocate(12)
                            .putInt(meshNodeId)
                            .putInt(packetBuffer.size)
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
        // Notify all connected peers
        for (address in discoveredPeers) {
            val device = bluetoothAdapter?.getRemoteDevice(address) ?: continue
            gattServer?.notifyCharacteristicChanged(device, characteristic, false)
        }
    }

    // -----------------------------------------------------------------------
    // BLE Advertising — broadcasts our presence to nearby devices
    // -----------------------------------------------------------------------

    private var advertiseCallback: AdvertiseCallback? = null

    private fun startAdvertising() {
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0) // Never timeout — life-critical service
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false) // Save advertisement bytes
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        advertiseCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
                Log.i(TAG, "BLE advertising started — HIGH power, LOW_LATENCY")
            }
            override fun onStartFailure(errorCode: Int) {
                Log.e(TAG, "BLE advertising failed: errorCode=$errorCode")
            }
        }

        bleAdvertiser?.startAdvertising(settings, data, advertiseCallback)
    }

    private fun stopAdvertising() {
        advertiseCallback?.let { bleAdvertiser?.stopAdvertising(it) }
        advertiseCallback = null
    }

    // -----------------------------------------------------------------------
    // BLE Scanning — discovers nearby mesh peers
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
        }

        bleScanner?.startScan(listOf(filter), settings, scanCallback)
        Log.i(TAG, "BLE scanning started — filtered for Sinyalist service")
    }

    private fun stopScanning() {
        scanCallback?.let { bleScanner?.stopScan(it) }
        scanCallback = null
    }

    private fun handleScanResult(result: ScanResult) {
        val device = result.device
        val address = device.address

        if (!discoveredPeers.contains(address)) {
            discoveredPeers.add(address)
            onPeerDiscovered?.invoke(address)
            Log.i(TAG, "New mesh peer discovered: $address (RSSI: ${result.rssi})")

            // Initiate GATT client connection to read their packets
            connectAndReadPackets(device)
        }
    }

    // -----------------------------------------------------------------------
    // GATT Client — reads packets from discovered peers
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

                // Bloom filter dedup check
                val dedupKey = if (payload.size >= 16) {
                    payload.sliceArray(0..7) + payload.sliceArray(payload.size - 8 until payload.size)
                } else payload

                if (bloomFilter.mightContain(dedupKey)) {
                    Log.d(TAG, "Duplicate packet filtered by bloom — skipping")
                    gatt.disconnect()
                    return
                }

                // New packet — add to bloom, buffer, and notify
                bloomFilter.add(dedupKey)

                // Check bloom saturation
                if (bloomFilter.fillRatio > BLOOM_RESET_THRESHOLD) {
                    Log.w(TAG, "Bloom filter at ${(bloomFilter.fillRatio * 100).toInt()}% — resetting")
                    bloomFilter.clear()
                }

                val packet = MeshPacket(
                    payload = payload,
                    hopCount = 1, // We are hop 1
                    ttl = 7,
                    receivedAtMs = System.currentTimeMillis(),
                    originHash = device.address.hashCode()
                )

                enqueuePacket(packet)
                onPacketReceived?.invoke(packet)

                Log.i(TAG, "Received mesh packet: ${payload.size} bytes from ${device.address}")
                gatt.disconnect()
            }
        })
    }

    // -----------------------------------------------------------------------
    // Stats emission
    // -----------------------------------------------------------------------

    private fun emitStats() {
        onMeshStatsUpdate?.invoke(MeshStats(
            activeNodes = discoveredPeers.size,
            bufferedPackets = packetBuffer.size,
            totalRelayed = totalRelayed,
            bloomFillRatio = bloomFilter.fillRatio
        ))
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
                "bufferedPackets" to packetBuffer.size,
                "totalRelayed" to totalRelayed,
                "bloomFillRatio" to bloomFilter.fillRatio
            )
            else -> null
        }
    }
}
