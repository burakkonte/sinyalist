// =============================================================================
// SINYALIST — iOS BLE Mesh Controller (CoreBluetooth GATT)
// =============================================================================
// iOS equivalent of Android NodusMeshController.kt.
//
// Architecture differences from Android:
//   Android: Connectionless BLE 5.0 advertising + GATT server/client hybrid
//   iOS:     GATT only (connectionless manufacturer-data advertising is blocked
//            in iOS background. Service UUID advertising works in background.)
//
// Interoperability: Uses the SAME Service/Characteristic UUIDs as Android,
// allowing cross-platform Android ↔ iOS mesh.
//
// Features:
//   • CBPeripheralManager — advertises service UUID, serves highest-priority
//     packet via PACKET_CHAR_UUID readable characteristic
//   • CBCentralManager   — scans for Sinyalist service UUID, connects to
//     peers, reads PACKET_CHAR, relays into local priority queue
//   • Priority queue: TRAPPED > MEDICAL > SOS > STATUS > CHAT
//   • SQLite persistence (sqlite3 C API, no pods) — store-carry-forward
//   • TTL enforcement — packets older than 1 hour are dropped
//   • FlutterStreamHandler — sends MeshStats to Dart at 2 Hz
// =============================================================================

import Foundation
import CoreBluetooth
import Flutter

// MARK: - UUIDs (must match NodusMeshController.kt)

private let kServiceUUID      = CBUUID(string: "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
private let kPacketCharUUID   = CBUUID(string: "a1b2c3d4-e5f6-7890-abcd-ef1234567891")
private let kMetaCharUUID     = CBUUID(string: "a1b2c3d4-e5f6-7890-abcd-ef1234567892")

// MARK: - Packet Priority

enum MeshPriority: Int, Comparable {
    case chat = 1, status = 2, sos = 3, medical = 4, trapped = 5

    static func < (lhs: MeshPriority, rhs: MeshPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    static func from(msgType: UInt8) -> MeshPriority {
        switch msgType {
        case 5: return .trapped
        case 4: return .medical
        case 3: return .sos
        case 2: return .status
        default: return .chat
        }
    }
}

// MARK: - Mesh Packet

private struct MeshPacket {
    let id: String
    let priority: MeshPriority
    let payload: Data
    let createdAtMs: Int64
    let ttlMs: Int64        // default 3_600_000 (1 hour)

    var isExpired: Bool {
        Int64(Date().timeIntervalSince1970 * 1000) - createdAtMs > ttlMs
    }
}

// MARK: - Mesh Stats (sent to Flutter)

struct MeshStatsSnapshot {
    var activeNodes: Int = 0
    var bufferedPackets: Int = 0
    var totalRelayed: Int = 0
    var bloomFillRatio: Double = 0
}

// MARK: - SinyalistMeshController

class SinyalistMeshController: NSObject, FlutterStreamHandler,
                               CBCentralManagerDelegate,
                               CBPeripheralManagerDelegate,
                               CBPeripheralDelegate {

    // Flutter EventChannel sink
    private var eventSink: FlutterEventSink?
    private let lock = NSLock()

    // CoreBluetooth
    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private var packetCharacteristic: CBMutableCharacteristic?
    private var metaCharacteristic: CBMutableCharacteristic?

    // Connected centrals (devices that subscribed to our notifications)
    private var subscribedCentrals: [CBCentral] = []
    // Peripherals we discovered and are reading from
    private var discoveredPeripherals: [CBPeripheral] = []

    // Priority queue
    private var queue: [MeshPacket] = []
    private let queueLock = NSLock()

    // Deduplication (simple LRU via dictionary with capacity limit)
    private var seenIds: [String: Int64] = [:]  // id → timestamp
    private let maxSeenIds = 5000

    // Statistics
    private var totalRelayed: Int = 0
    private var activeNodeIds: Set<String> = []
    private var isInitialized = false

    // Persistence
    private var db: OpaquePointer?

    // Stats timer
    private var statsTimer: Timer?

    // MARK: - Flutter StreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        lock.lock(); defer { lock.unlock() }
        eventSink = events
        startStatsTimer()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        lock.lock(); defer { lock.unlock() }
        eventSink = nil
        statsTimer?.invalidate()
        statsTimer = nil
        return nil
    }

    // MARK: - Lifecycle

    func initialize() -> Bool {
        guard !isInitialized else { return true }
        isInitialized = true
        openDatabase()
        loadPersisted()

        let centralOptions: [String: Any] = [
            CBCentralManagerOptionRestoreIdentifierKey: "com.sinyalist.central"
        ]
        let peripheralOptions: [String: Any] = [
            CBPeripheralManagerOptionRestoreIdentifierKey: "com.sinyalist.peripheral"
        ]

        centralManager = CBCentralManager(
            delegate: self, queue: nil, options: centralOptions
        )
        peripheralManager = CBPeripheralManager(
            delegate: self, queue: nil, options: peripheralOptions
        )

        print("[MeshController] Initialized — GATT central+peripheral")
        return true
    }

    func startMesh() {
        // Advertising and scanning are started automatically when managers power on
        // (in centralManagerDidUpdateState / peripheralManagerDidUpdateState)
        print("[MeshController] startMesh called")
    }

    func stopMesh() {
        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()
        statsTimer?.invalidate()
        statsTimer = nil
        persistQueue()
        closeDatabase()
        print("[MeshController] Stopped")
    }

    func broadcastPacket(_ payload: Data) {
        let id = UUID().uuidString
        let msgType: UInt8 = payload.count > 0 ? payload[0] : 0
        let priority = MeshPriority.from(msgType: msgType)
        let packet = MeshPacket(
            id: id,
            priority: priority,
            payload: payload,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            ttlMs: 3_600_000
        )
        enqueue(packet)
        persistPacket(packet)
        // Update characteristic so subscribed centrals get notified
        updateAdvertisedCharacteristic()
        print("[MeshController] Packet enqueued priority=\(priority) size=\(payload.count)B")
    }

    func getStats() -> [String: Any] {
        queueLock.lock()
        let buffered = queue.count
        let relayed = totalRelayed
        let nodes = activeNodeIds.count
        queueLock.unlock()
        return [
            "activeNodes":      nodes,
            "bufferedPackets":  buffered,
            "totalRelayed":     relayed,
            "bloomFillRatio":   Double(seenIds.count) / Double(maxSeenIds),
        ]
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("[MeshController] Central powered on — starting scan")
            startScanning()
        case .poweredOff:
            print("[MeshController] Bluetooth off")
        default:
            print("[MeshController] Central state: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let id = peripheral.identifier.uuidString
        if !activeNodeIds.contains(id) {
            activeNodeIds.insert(id)
        }
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
            print("[MeshController] Discovered peer: \(id)")
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([kServiceUUID])
        print("[MeshController] Connected to \(peripheral.identifier)")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        discoveredPeripherals.removeAll { $0.identifier == peripheral.identifier }
        activeNodeIds.remove(peripheral.identifier.uuidString)
        print("[MeshController] Disconnected: \(peripheral.identifier)")
        // Rescan to find the peer again
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.startScanning()
        }
    }

    // State restoration
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for p in peripherals {
                p.delegate = self
                discoveredPeripherals.append(p)
            }
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        for service in peripheral.services ?? [] {
            if service.uuid == kServiceUUID {
                peripheral.discoverCharacteristics([kPacketCharUUID, kMetaCharUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else { return }
        for char in service.characteristics ?? [] {
            if char.uuid == kPacketCharUUID {
                peripheral.readValue(for: char)
                // Subscribe to notifications for future packets
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil,
              characteristic.uuid == kPacketCharUUID,
              let data = characteristic.value,
              !data.isEmpty else { return }

        relayInboundPacket(data, fromPeer: peripheral.identifier.uuidString)
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            print("[MeshController] Peripheral powered on — setting up GATT service")
            setupGattService()
        default:
            print("[MeshController] Peripheral state: \(peripheral.state.rawValue)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didAdd service: CBService,
                           error: Error?) {
        if let error = error {
            print("[MeshController] GATT service add error: \(error)")
            return
        }
        startAdvertising()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
        }
        // Send top-priority packet immediately on subscribe
        updateAdvertisedCharacteristic()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
    }

    // State restoration
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            for service in services {
                for char in service.characteristics ?? [] {
                    if char.uuid == kPacketCharUUID { packetCharacteristic = char as? CBMutableCharacteristic }
                    if char.uuid == kMetaCharUUID   { metaCharacteristic   = char as? CBMutableCharacteristic }
                }
            }
        }
    }

    // MARK: - Private: BLE setup

    private func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        // allowDuplicates: false in background (iOS restriction)
        let scanOptions: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        centralManager.scanForPeripherals(withServices: [kServiceUUID], options: scanOptions)
        print("[MeshController] Scanning for Sinyalist peers…")
    }

    private func setupGattService() {
        let packetChar = CBMutableCharacteristic(
            type: kPacketCharUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: .readable
        )
        let metaChar = CBMutableCharacteristic(
            type: kMetaCharUUID,
            properties: [.read],
            value: nil,
            permissions: .readable
        )
        packetCharacteristic = packetChar
        metaCharacteristic = metaChar

        let service = CBMutableService(type: kServiceUUID, primary: true)
        service.characteristics = [packetChar, metaChar]
        peripheralManager.add(service)
        print("[MeshController] GATT service added — service: \(kServiceUUID)")
    }

    private func startAdvertising() {
        let advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [kServiceUUID],
            CBAdvertisementDataLocalNameKey: "Sinyalist"
        ]
        peripheralManager.startAdvertising(advertisementData)
        print("[MeshController] Advertising started (service UUID visible in background)")
    }

    private func updateAdvertisedCharacteristic() {
        guard let char = packetCharacteristic else { return }
        queueLock.lock()
        let topPacket = queue.max(by: { $0.priority < $1.priority })
        queueLock.unlock()

        let data = topPacket?.payload ?? Data()
        char.value = data

        if !subscribedCentrals.isEmpty {
            peripheralManager.updateValue(data, for: char, onSubscribedCentrals: subscribedCentrals)
        }
    }

    // MARK: - Queue Management

    private func enqueue(_ packet: MeshPacket) {
        queueLock.lock(); defer { queueLock.unlock() }
        guard !isDuplicate(packet.id) else { return }
        markSeen(packet.id)
        queue.append(packet)
        queue.sort { $0.priority > $1.priority }
        // Trim expired
        queue.removeAll { $0.isExpired }
        // Cap at 500
        if queue.count > 500 { queue = Array(queue.prefix(500)) }
    }

    private func relayInboundPacket(_ data: Data, fromPeer peer: String) {
        let id = data.prefix(16).map { String(format: "%02x", $0) }.joined()
        guard !isDuplicate(id) else { return }
        markSeen(id)

        let packet = MeshPacket(
            id: id, priority: .sos, payload: data,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            ttlMs: 3_600_000
        )
        queueLock.lock()
        queue.append(packet)
        queue.sort { $0.priority > $1.priority }
        totalRelayed += 1
        queueLock.unlock()

        persistPacket(packet)
        updateAdvertisedCharacteristic()
        print("[MeshController] Relayed packet from \(peer) size=\(data.count)B")
    }

    private func isDuplicate(_ id: String) -> Bool { seenIds[id] != nil }

    private func markSeen(_ id: String) {
        if seenIds.count >= maxSeenIds {
            // Evict oldest entry
            if let oldest = seenIds.min(by: { $0.value < $1.value }) {
                seenIds.removeValue(forKey: oldest.key)
            }
        }
        seenIds[id] = Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Stats Timer

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let stats = self.getStats()
            self.lock.lock()
            self.eventSink?(stats)
            self.lock.unlock()
        }
    }

    // MARK: - SQLite Persistence

    private func dbPath() -> String {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        return "\(docs)/sinyalist_mesh.db"
    }

    private func openDatabase() {
        let path = dbPath()
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            print("[MeshController] Failed to open SQLite database")
            return
        }
        let create = """
            CREATE TABLE IF NOT EXISTS mesh_packets (
                id TEXT PRIMARY KEY,
                priority INTEGER NOT NULL,
                payload BLOB NOT NULL,
                ttl_ms INTEGER NOT NULL,
                created_at INTEGER NOT NULL
            );
        """
        sqlite3_exec(db, create, nil, nil, nil)
        print("[MeshController] SQLite database opened: \(path)")
    }

    private func closeDatabase() {
        guard db != nil else { return }
        sqlite3_close(db)
        db = nil
    }

    private func persistPacket(_ packet: MeshPacket) {
        guard db != nil else { return }
        let sql = "INSERT OR REPLACE INTO mesh_packets (id,priority,payload,ttl_ms,created_at) VALUES (?,?,?,?,?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (packet.id as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(packet.priority.rawValue))
        packet.payload.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(packet.payload.count), nil)
        }
        sqlite3_bind_int64(stmt, 4, packet.ttlMs)
        sqlite3_bind_int64(stmt, 5, packet.createdAtMs)
        sqlite3_step(stmt)
    }

    private func loadPersisted() {
        guard db != nil else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let sql = "SELECT id,priority,payload,ttl_ms,created_at FROM mesh_packets WHERE (created_at + ttl_ms) > ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, nowMs)
        var count = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id       = String(cString: sqlite3_column_text(stmt, 0))
            let pri      = MeshPriority(rawValue: Int(sqlite3_column_int(stmt, 1))) ?? .chat
            let len      = sqlite3_column_bytes(stmt, 2)
            let raw      = sqlite3_column_blob(stmt, 2)
            let payload  = raw != nil ? Data(bytes: raw!, count: Int(len)) : Data()
            let ttlMs    = sqlite3_column_int64(stmt, 3)
            let created  = sqlite3_column_int64(stmt, 4)

            queue.append(MeshPacket(id: id, priority: pri, payload: payload,
                                    createdAtMs: created, ttlMs: ttlMs))
            count += 1
        }
        queue.sort { $0.priority > $1.priority }
        print("[MeshController] Loaded \(count) persisted packets from SQLite")

        // Delete expired rows
        sqlite3_exec(db, "DELETE FROM mesh_packets WHERE (created_at + ttl_ms) <= \(nowMs);", nil, nil, nil)
    }

    private func persistQueue() {
        queueLock.lock()
        let snapshot = queue
        queueLock.unlock()
        snapshot.forEach { persistPacket($0) }
    }
}
