package com.satview.bondcam.srtla

import android.net.Network
import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketAddress
import java.security.SecureRandom

/**
 * SRTLA bonding core on the phone side (matches BELABOX srtla_rec on the server).
 * The SRT library (camera/mic) sends to 127.0.0.1:localPort. We split the
 * packets across several UDP links (one bound to WiFi, one to cellular) by
 * link quality. srtla_rec on the server merges them back into one SRT stream.
 */
class SrtlaSender(
    private val localPort: Int,
    private val serverHost: String,
    private val serverPort: Int,
    private val onStatus: (String) -> Unit
) {
    companion object { private const val TAG = "SrtlaSender" }

    private val lock = Any()
    private val conns = LinkedHashMap<String, SrtlaConnection>()
    private var serverAddr: InetSocketAddress? = null
    private val pendingNetworks = LinkedHashMap<String, Network?>()

    private val reg1Id = ByteArray(SrtlaProto.ID_LEN).also { SecureRandom().nextBytes(it) }
    @Volatile private var groupId: ByteArray? = null
    @Volatile private var lastReg1Ms = 0L

    private var localSocket: DatagramSocket? = null
    @Volatile private var localPeer: SocketAddress? = null
    @Volatile private var running = false

    // Recent bytes sent per link (decayed in housekeeping) - used for
    // LiveU-style balanced scheduling across all healthy links.
    private val sentRecent = HashMap<SrtlaConnection, Long>()

    // Recent loss events per link (decayed in housekeeping). A link with
    // recent losses is "weak": it gets a small probe share instead of 50%,
    // and returns to full balance automatically once losses stop.
    private val lossRecent = HashMap<SrtlaConnection, Long>()

    fun start() {
        running = true
        Thread({
            // Bind explicitly to IPv4 loopback: InetAddress.getLoopbackAddress()
            // may return ::1 (IPv6) on some devices while the SRT library sends
            // to 127.0.0.1 -> "ICMP Port Unreachable".
            val sock = try {
                DatagramSocket(InetSocketAddress(InetAddress.getByName("127.0.0.1"), localPort))
            } catch (e: Exception) {
                Log.e(TAG, "local bind failed", e)
                onStatus("שגיאה בפתיחת פורט מקומי $localPort: ${e.message}")
                return@Thread
            }
            localSocket = sock

            while (running && serverAddr == null) {
                try {
                    serverAddr = InetSocketAddress(InetAddress.getByName(serverHost), serverPort)
                    onStatus("שרת: $serverHost")
                } catch (e: Exception) {
                    onStatus("שגיאת DNS ל-$serverHost, מנסה שוב...")
                    Thread.sleep(2000)
                }
            }
            if (!running) return@Thread

            synchronized(lock) {
                for ((name, net) in pendingNetworks) createConn(name, net)
                pendingNetworks.clear()
            }

            Thread({ housekeepingLoop() }, "srtla-housekeeping").start()
            localLoop(sock)
        }, "srtla-local").start()
    }

    fun stop() {
        running = false
        synchronized(lock) {
            for (c in conns.values) c.close()
            conns.clear()
        }
        try { localSocket?.close() } catch (e: Exception) {}
    }

    fun addNetwork(name: String, network: Network?) {
        synchronized(lock) {
            if (serverAddr == null) { pendingNetworks[name] = network; return }
            createConn(name, network)
        }
    }

    fun removeNetwork(name: String) {
        synchronized(lock) {
            conns.remove(name)?.close()
        }
        onStatus("רשת נותקה: $name")
    }

    private fun createConn(name: String, network: Network?) {
        conns.remove(name)?.close()
        val addr = serverAddr ?: return
        try {
            val conn = SrtlaConnection(name, network, addr)
            conns[name] = conn
            Thread({ connReceiveLoop(conn) }, "srtla-rx-$name").start()
            val id = groupId
            if (id != null) sendReg2(conn, id)
            onStatus("רשת נוספה: $name")
        } catch (e: Exception) {
            Log.e(TAG, "createConn $name failed", e)
        }
    }

    private fun localLoop(sock: DatagramSocket) {
        val buf = ByteArray(SrtlaProto.MTU)
        while (running) {
            try {
                val pkt = DatagramPacket(buf, buf.size)
                sock.receive(pkt)
                localPeer = pkt.socketAddress
                val len = pkt.length
                val isControl = len >= 2 && (buf[0].toInt() and 0x80) != 0
                // SRT control type (0x0000 = handshake). Handshakes must NOT
                // be duplicated - a doubled handshake confuses the server.
                val ctrlType = if (isControl) ((buf[0].toInt() and 0x7F) shl 8) or (buf[1].toInt() and 0xFF) else -1
                val isHandshake = isControl && ctrlType == 0x0000
                // SRT data header: R (retransmit) flag = bit 2 of byte 4
                val isRetx = !isControl && len >= 8 && (buf[4].toInt() and 0x04) != 0
                synchronized(lock) {
                    if (isControl && !isHandshake) {
                        // Critical SRT control (acks/keepalive/nak):
                        // duplicate on ALL healthy links - never lose these.
                        var sent = false
                        for (c in conns.values) {
                            if (c.registered && !c.closed) { c.send(buf, len); sent = true }
                        }
                        if (!sent) selectConn()?.send(buf, len)
                        return@synchronized
                    }
                    if (isHandshake) {
                        // Single path only, on the healthiest link.
                        selectConn()?.send(buf, len)
                        return@synchronized
                    }
                    val conn = selectConn() ?: return@synchronized
                    if (SrtlaProto.isSrtData(buf, len)) {
                        conn.inFlight.add(SrtlaProto.dataSeq(buf))
                        if (conn.inFlight.size > 10000) conn.inFlight.clear()
                    }
                    conn.send(buf, len)
                    sentRecent[conn] = (sentRecent[conn] ?: 0L) + len
                    // LiveU-style protection: retransmitted packets, and any
                    // packet probing a weak link, are duplicated on the best
                    // other link so recovery never depends on a shaky path.
                    if (isRetx || isWeak(conn)) {
                        bestOther(conn)?.send(buf, len)
                    }
                }
            } catch (e: Exception) {
                if (running) Log.w(TAG, "localLoop: ${e.message}")
            }
        }
    }

    /** Best registered link other than [not] - prefers healthy links. */
    private fun bestOther(not: SrtlaConnection): SrtlaConnection? {
        var best: SrtlaConnection? = null
        var bestLoad = Double.MAX_VALUE
        for (c in conns.values) {
            if (c === not || !c.registered || c.closed) continue
            val load = (sentRecent[c] ?: 0L).toDouble() / linkWeight(c)
            if (load < bestLoad) { bestLoad = load; best = c }
        }
        return best
    }

    /**
     * A link is "weak" only on hard evidence:
     *  - it timed out / stopped answering (lossRecent set to 100 on timeout), or
     *  - a large backlog of packets it carried were never confirmed by the
     *    SRTLA receiver (the link itself is stalling).
     * SRT NAKs are deliberately NOT counted here: with two paths of different
     * latency the receiver reports the slower path's in-flight packets as
     * "lost" (reorder), which would wrongly demote a perfectly good link.
     */
    private fun isWeak(c: SrtlaConnection): Boolean =
        (lossRecent[c] ?: 0L) >= 5 || c.inFlight.size > 400

    /**
     * Balanced scheduler (LiveU-style): all healthy links share the traffic
     * equally (50/50 with two links) regardless of history. A link with
     * recent packet loss becomes "weak" and drops to a ~10% probe share so
     * we keep measuring it; once the losses stop it returns to full balance
     * automatically. Unregistered or closed links are never picked.
     */
    /**
     * Link weight: 1.0 for a healthy free-flowing link, smoothly reduced as
     * its unconfirmed backlog grows (graceful preference for the stronger
     * network), and 0.1 for a hard-failed link (probe share).
     */
    private fun linkWeight(c: SrtlaConnection): Double {
        val base = if (isWeak(c)) 0.1 else 1.0
        return base / (1.0 + c.inFlight.size / 150.0)
    }

    private fun selectConn(): SrtlaConnection? {
        var best: SrtlaConnection? = null
        var bestLoad = Double.MAX_VALUE
        for (c in conns.values) {
            if (!c.registered || c.closed) continue
            val load = (sentRecent[c] ?: 0L).toDouble() / linkWeight(c)
            if (load < bestLoad) { bestLoad = load; best = c }
        }
        return best
    }

    private fun connReceiveLoop(conn: SrtlaConnection) {
        val buf = ByteArray(SrtlaProto.MTU)
        while (running && !conn.closed) {
            try {
                val pkt = DatagramPacket(buf, buf.size)
                conn.socket.receive(pkt)
                conn.lastReceivedMs = System.currentTimeMillis()
                val len = pkt.length
                when (val type = SrtlaProto.packetType(buf, len)) {
                    SrtlaProto.TYPE_ACK -> handleSrtlaAck(conn, buf, len)
                    SrtlaProto.TYPE_KEEPALIVE -> { }
                    SrtlaProto.TYPE_REG2 -> {
                        if (len >= 2 + SrtlaProto.ID_LEN && groupId == null) {
                            groupId = buf.copyOfRange(2, 2 + SrtlaProto.ID_LEN)
                            Log.i(TAG, "got group id, registering all links")
                            synchronized(lock) {
                                for (c in conns.values) sendReg2(c, groupId!!)
                            }
                        }
                    }
                    SrtlaProto.TYPE_REG3 -> {
                        if (!conn.registered) {
                            conn.registered = true
                            onStatus("קישור פעיל: ${conn.name}")
                        }
                    }
                    SrtlaProto.TYPE_REG_NGP -> { groupId = null }
                    SrtlaProto.TYPE_REG_ERR, SrtlaProto.TYPE_REG_NAK -> {
                        // Stale/rejected group: start a fresh registration cycle.
                        groupId = null
                        conn.registered = false
                        Log.w(TAG, "srtla registration error (${Integer.toHexString(type)})")
                    }
                    else -> {
                        if (type == SrtlaProto.SRT_TYPE_ACK && len >= 20) handleSrtAck(buf)
                        if (type == SrtlaProto.SRT_TYPE_NAK && len >= 20) handleSrtNak(buf, len)
                        forwardToLocal(buf, len)
                    }
                }
            } catch (e: Exception) {
                if (running && !conn.closed) Log.w(TAG, "rx ${conn.name}: ${e.message}")
            }
        }
    }

    private fun forwardToLocal(buf: ByteArray, len: Int) {
        val peer = localPeer ?: return
        try { localSocket?.send(DatagramPacket(buf, len, peer)) } catch (e: Exception) {}
    }

    private fun handleSrtlaAck(conn: SrtlaConnection, buf: ByteArray, len: Int) {
        synchronized(lock) {
            var off = 4
            while (off + 4 <= len) {
                val seq = SrtlaProto.int32At(buf, off) and 0x7FFFFFFF
                if (conn.inFlight.remove(seq)) {
                    conn.window = minOf(conn.window + SrtlaProto.WINDOW_INCR, SrtlaProto.WINDOW_MAX)
                }
                off += 4
            }
        }
    }

    private fun handleSrtAck(buf: ByteArray) {
        val lastAck = SrtlaProto.int32At(buf, 16) and 0x7FFFFFFF
        synchronized(lock) {
            for (c in conns.values) {
                c.inFlight.removeAll { seq -> SrtlaProto.seqBefore(seq, lastAck) }
            }
        }
    }

    private fun handleSrtNak(buf: ByteArray, len: Int) {
        synchronized(lock) {
            var off = 16
            while (off + 4 <= len) {
                val v = SrtlaProto.int32At(buf, off)
                if (v < 0) {
                    val start = v and 0x7FFFFFFF
                    off += 4
                    if (off + 4 > len) break
                    val end = SrtlaProto.int32At(buf, off) and 0x7FFFFFFF
                    var s = start
                    var guard = 0
                    while (guard < 2000) {
                        penalizeLoss(s)
                        if (s == end) break
                        s = (s + 1) and 0x7FFFFFFF
                        guard++
                    }
                } else {
                    penalizeLoss(v and 0x7FFFFFFF)
                }
                off += 4
            }
        }
    }

    private fun penalizeLoss(seq: Int) {
        for (c in conns.values) {
            if (c.inFlight.remove(seq)) {
                c.window = maxOf(c.window - SrtlaProto.WINDOW_DECR, SrtlaProto.WINDOW_MIN)
                // Note: intentionally NOT counted toward isWeak() - SRT NAKs
                // include reorder false-positives across paths.
                return
            }
        }
    }

    private fun sendReg1(conn: SrtlaConnection) {
        conn.send(SrtlaProto.buildControl(SrtlaProto.TYPE_REG1, reg1Id), 2 + SrtlaProto.ID_LEN)
    }

    private fun sendReg2(conn: SrtlaConnection, id: ByteArray) {
        conn.lastRegSentMs = System.currentTimeMillis()
        conn.send(SrtlaProto.buildControl(SrtlaProto.TYPE_REG2, id), 2 + SrtlaProto.ID_LEN)
    }

    private fun housekeepingLoop() {
        val keepalive = SrtlaProto.buildControl(SrtlaProto.TYPE_KEEPALIVE)
        while (running) {
            try {
                val now = System.currentTimeMillis()
                synchronized(lock) {
                    if (groupId == null && conns.isNotEmpty() && now - lastReg1Ms > SrtlaProto.REG_RETRY_MS) {
                        lastReg1Ms = now
                        sendReg1(conns.values.first())
                    }
                    for (c in conns.values) {
                        if (now - c.lastKeepaliveMs > SrtlaProto.KEEPALIVE_INTERVAL_MS) {
                            c.lastKeepaliveMs = now
                            c.send(keepalive, keepalive.size)
                        }
                        // Fast failover: a link silent for >1.5s is demoted to
                        // weak immediately (probe share + duplication cover it)
                        if (c.registered && now - c.lastReceivedMs > 1500) {
                            lossRecent[c] = maxOf(lossRecent[c] ?: 0L, 6L)
                        }
                        if (c.registered && now - c.lastReceivedMs > SrtlaProto.CONN_TIMEOUT_MS) {
                            c.registered = false
                            c.inFlight.clear()
                            c.window = SrtlaProto.WINDOW_MIN * 2
                            lossRecent[c] = 100
                            onStatus("קישור איטי/נפל: ${c.name}")
                        }
                        val id = groupId
                        if (!c.registered && id != null && now - c.lastRegSentMs > SrtlaProto.REG_RETRY_MS) {
                            sendReg2(c, id)
                        }
                        c.window = minOf(c.window + 1, SrtlaProto.WINDOW_MAX)
                    }
                    // Decay recent-bytes counters (~1s half-life at 200ms tick)
                    for (k in sentRecent.keys.toList()) {
                        sentRecent[k] = (sentRecent[k] ?: 0L) * 4 / 5
                    }
                    sentRecent.keys.retainAll(conns.values.toSet())
                    // Decay loss counters (~3s to recover from a loss burst)
                    for (k in lossRecent.keys.toList()) {
                        lossRecent[k] = (lossRecent[k] ?: 0L) * 9 / 10
                    }
                    lossRecent.keys.retainAll(conns.values.toSet())
                }
                Thread.sleep(200)
            } catch (e: InterruptedException) {
                return
            } catch (e: Exception) {
                Log.w(TAG, "housekeeping: ${e.message}")
            }
        }
    }

    // How many links are currently registered (checked before opening SRT)
    fun registeredCount(): Int = synchronized(lock) { conns.values.count { it.registered } }

    fun statusLine(): String = synchronized(lock) {
        val total = conns.values.sumOf { sentRecent[it] ?: 0L }.coerceAtLeast(1L)
        conns.values.joinToString("  |  ") { c ->
            val st = when {
                !c.registered -> "מתחבר"
                isWeak(c) -> "חלש"
                else -> "פעיל"
            }
            val pct = (sentRecent[c] ?: 0L) * 100 / total
            "${c.name}: $st $pct%"
        }
    }
}
