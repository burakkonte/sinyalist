// =============================================================================
// SINYALIST — MeshPacketStore (SQLite persistence for store-carry-forward)
// =============================================================================
// Lightweight SQLite helper using android.database.sqlite (no Room dependency).
// Thread-safe: all public methods synchronize on the database lock.
// =============================================================================

package com.sinyalist.mesh

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Log

class MeshPacketStore(context: Context) : SQLiteOpenHelper(
    context,
    DATABASE_NAME,
    null,
    DATABASE_VERSION
) {

    companion object {
        private const val TAG = "MeshPacketStore"
        private const val DATABASE_NAME = "sinyalist_mesh.db"
        private const val DATABASE_VERSION = 1

        private const val TABLE = "mesh_packets"
        private const val COL_ID = "id"
        private const val COL_DEDUP_KEY = "dedup_key"
        private const val COL_PAYLOAD = "payload"
        private const val COL_HOP_COUNT = "hop_count"
        private const val COL_TTL = "ttl"
        private const val COL_RECEIVED_AT_MS = "received_at_ms"
        private const val COL_ORIGIN_HASH = "origin_hash"
        private const val COL_MSG_TYPE = "msg_type"
        private const val COL_IS_TRAPPED = "is_trapped"
        private const val COL_PRIORITY = "priority"

        private const val SQL_CREATE_TABLE = """
            CREATE TABLE IF NOT EXISTS $TABLE (
                $COL_ID            INTEGER PRIMARY KEY AUTOINCREMENT,
                $COL_DEDUP_KEY     TEXT UNIQUE,
                $COL_PAYLOAD       BLOB,
                $COL_HOP_COUNT     INTEGER,
                $COL_TTL           INTEGER,
                $COL_RECEIVED_AT_MS INTEGER,
                $COL_ORIGIN_HASH   INTEGER,
                $COL_MSG_TYPE      INTEGER,
                $COL_IS_TRAPPED    INTEGER,
                $COL_PRIORITY      INTEGER
            )
        """

        private const val SQL_CREATE_INDEX_RECEIVED =
            "CREATE INDEX IF NOT EXISTS idx_received ON $TABLE ($COL_RECEIVED_AT_MS)"

        private const val SQL_CREATE_INDEX_PRIORITY =
            "CREATE INDEX IF NOT EXISTS idx_priority ON $TABLE ($COL_PRIORITY)"
    }

    // Lock object for thread safety on compound operations
    private val dbLock = Object()

    // -----------------------------------------------------------------------
    // Schema management
    // -----------------------------------------------------------------------

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(SQL_CREATE_TABLE)
        db.execSQL(SQL_CREATE_INDEX_RECEIVED)
        db.execSQL(SQL_CREATE_INDEX_PRIORITY)
        Log.i(TAG, "Created mesh_packets table (v$DATABASE_VERSION)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        Log.w(TAG, "Upgrading database from v$oldVersion to v$newVersion — dropping and recreating")
        db.execSQL("DROP TABLE IF EXISTS $TABLE")
        onCreate(db)
    }

    override fun onDowngrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        onUpgrade(db, oldVersion, newVersion)
    }

    // -----------------------------------------------------------------------
    // insertPacket — INSERT OR IGNORE, returns true if a new row was inserted
    // -----------------------------------------------------------------------

    fun insertPacket(packet: MeshPacket): Boolean {
        synchronized(dbLock) {
            val db = writableDatabase
            val dedupHex = packet.dedupKey().toHexString()

            val values = ContentValues().apply {
                put(COL_DEDUP_KEY, dedupHex)
                put(COL_PAYLOAD, packet.payload)
                put(COL_HOP_COUNT, packet.hopCount)
                put(COL_TTL, packet.ttl)
                put(COL_RECEIVED_AT_MS, packet.receivedAtMs)
                put(COL_ORIGIN_HASH, packet.originHash)
                put(COL_MSG_TYPE, packet.msgType)
                put(COL_IS_TRAPPED, if (packet.isTrapped) 1 else 0)
                put(COL_PRIORITY, packet.priority.level)
            }

            val rowId = db.insertWithOnConflict(
                TABLE,
                null,
                values,
                SQLiteDatabase.CONFLICT_IGNORE
            )

            val isNew = rowId != -1L
            if (isNew) {
                Log.d(TAG, "Persisted packet dedup=$dedupHex priority=${packet.priority}")
            } else {
                Log.d(TAG, "Packet already persisted dedup=$dedupHex (IGNORE)")
            }
            return isNew
        }
    }

    // -----------------------------------------------------------------------
    // loadPendingPackets — all non-expired packets, ordered by priority ASC
    //                      (TRAPPED = 0 first, then MEDICAL, SOS, etc.)
    // -----------------------------------------------------------------------

    fun loadPendingPackets(): List<MeshPacket> {
        synchronized(dbLock) {
            val db = readableDatabase
            val cutoff = System.currentTimeMillis() - MeshPacket.PACKET_TTL_MS
            val packets = mutableListOf<MeshPacket>()

            val cursor = db.query(
                TABLE,
                null,
                "$COL_RECEIVED_AT_MS >= ?",
                arrayOf(cutoff.toString()),
                null,
                null,
                "$COL_PRIORITY ASC, $COL_RECEIVED_AT_MS ASC"
            )

            cursor.use { c ->
                val iPayload = c.getColumnIndexOrThrow(COL_PAYLOAD)
                val iHop = c.getColumnIndexOrThrow(COL_HOP_COUNT)
                val iTtl = c.getColumnIndexOrThrow(COL_TTL)
                val iReceived = c.getColumnIndexOrThrow(COL_RECEIVED_AT_MS)
                val iOrigin = c.getColumnIndexOrThrow(COL_ORIGIN_HASH)
                val iMsgType = c.getColumnIndexOrThrow(COL_MSG_TYPE)
                val iTrapped = c.getColumnIndexOrThrow(COL_IS_TRAPPED)

                while (c.moveToNext()) {
                    packets.add(
                        MeshPacket(
                            payload = c.getBlob(iPayload),
                            hopCount = c.getInt(iHop),
                            ttl = c.getInt(iTtl),
                            receivedAtMs = c.getLong(iReceived),
                            originHash = c.getInt(iOrigin),
                            msgType = c.getInt(iMsgType),
                            isTrapped = c.getInt(iTrapped) != 0
                        )
                    )
                }
            }

            Log.i(TAG, "Loaded ${packets.size} pending packets from SQLite")
            return packets
        }
    }

    // -----------------------------------------------------------------------
    // deleteExpired — remove packets older than ttlMs from now
    // -----------------------------------------------------------------------

    fun deleteExpired(ttlMs: Long) {
        synchronized(dbLock) {
            val db = writableDatabase
            val cutoff = System.currentTimeMillis() - ttlMs
            val deleted = db.delete(
                TABLE,
                "$COL_RECEIVED_AT_MS < ?",
                arrayOf(cutoff.toString())
            )
            if (deleted > 0) {
                Log.i(TAG, "Deleted $deleted expired packets (cutoff=${cutoff}ms)")
            }
        }
    }

    // -----------------------------------------------------------------------
    // deleteByDedupKey — remove a specific packet by its dedup key
    // -----------------------------------------------------------------------

    fun deleteByDedupKey(key: ByteArray) {
        synchronized(dbLock) {
            val db = writableDatabase
            val hex = key.toHexString()
            val deleted = db.delete(
                TABLE,
                "$COL_DEDUP_KEY = ?",
                arrayOf(hex)
            )
            if (deleted > 0) {
                Log.d(TAG, "Deleted packet dedup=$hex")
            }
        }
    }

    // -----------------------------------------------------------------------
    // count — total rows in the table
    // -----------------------------------------------------------------------

    fun count(): Int {
        synchronized(dbLock) {
            val db = readableDatabase
            val cursor = db.rawQuery("SELECT COUNT(*) FROM $TABLE", null)
            cursor.use { c ->
                return if (c.moveToFirst()) c.getInt(0) else 0
            }
        }
    }

    // -----------------------------------------------------------------------
    // clear — delete all rows
    // -----------------------------------------------------------------------

    fun clear() {
        synchronized(dbLock) {
            val db = writableDatabase
            db.delete(TABLE, null, null)
            Log.i(TAG, "Cleared all packets from SQLite")
        }
    }

    // -----------------------------------------------------------------------
    // Utility
    // -----------------------------------------------------------------------

    private fun ByteArray.toHexString(): String {
        return joinToString("") { "%02x".format(it) }
    }
}
