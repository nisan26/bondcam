package com.satview.bondcam

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.SurfaceHolder
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.pedro.common.ConnectChecker
import com.pedro.common.VideoCodec
import com.pedro.common.socket.base.SocketType
import com.pedro.library.srt.SrtCamera2
import com.pedro.library.view.OpenGlView
import com.satview.bondcam.srtla.BondingNetworks
import com.satview.bondcam.srtla.SrtlaSender

class MainActivity : AppCompatActivity(), ConnectChecker, SurfaceHolder.Callback {

    companion object {
        private const val LOCAL_SRT_PORT = 6000
        private const val DIRECT_PORT = 8890
        private const val BONDING_PORT = 5001
        private const val PREFS = "bondcam"
    }

    private lateinit var openGlView: OpenGlView
    private lateinit var btnStart: Button
    private lateinit var tvStatus: TextView
    private lateinit var tvReporter: TextView
    private lateinit var etHost: EditText
    private lateinit var etPort: EditText
    private lateinit var etBitrate: EditText
    private lateinit var etStreamId: EditText

    private var camera: SrtCamera2? = null
    private var sender: SrtlaSender? = null
    private var networks: BondingNetworks? = null
    private var streaming = false
    @Volatile private var srtStarted = false

    private var reporterName = ""

    private val ui = Handler(Looper.getMainLooper())
    private val statusTicker = object : Runnable {
        override fun run() {
            sender?.let { tvStatus.text = it.statusLine() }
            ui.postDelayed(this, 1000)
        }
    }

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
            val cam = grants[Manifest.permission.CAMERA] ?: false
            val mic = grants[Manifest.permission.RECORD_AUDIO] ?: false
            if (cam && mic) initCamera()
            else Toast.makeText(this, "חייבים הרשאת מצלמה ומיקרופון", Toast.LENGTH_LONG).show()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        openGlView = findViewById(R.id.openGlView)
        btnStart = findViewById(R.id.btnStart)
        tvStatus = findViewById(R.id.tvStatus)
        tvReporter = findViewById(R.id.tvReporter)
        etHost = findViewById(R.id.etHost)
        etPort = findViewById(R.id.etPort)
        etBitrate = findViewById(R.id.etBitrate)
        etStreamId = findViewById(R.id.etStreamId)

        openGlView.holder.addCallback(this)
        btnStart.setOnClickListener { if (streaming) stopAll() else startAll() }

        loadPrefs()
        handleSetupLink(intent)          // bondcam://setup?... (cold start)

        if (hasPermissions()) initCamera()
        else permissionLauncher.launch(neededPermissions())
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleSetupLink(intent)          // app already running
    }

    /* ---------- provisioning ---------- */

    /**
     * A reporter is provisioned with one tap from the control room:
     *   bondcam://setup?host=satview.ddns.net&port=8890&sid=publish:app3&name=Dani
     * Nothing to type, nothing to get wrong.
     */
    private fun handleSetupLink(intent: Intent?) {
        val uri: Uri = intent?.data ?: return
        if (uri.scheme != "bondcam") return

        uri.getQueryParameter("host")?.takeIf { it.isNotBlank() }?.let { etHost.setText(it) }
        uri.getQueryParameter("port")?.takeIf { it.isNotBlank() }?.let { etPort.setText(it) }
        uri.getQueryParameter("sid")?.takeIf { it.isNotBlank() }?.let { etStreamId.setText(it) }
        uri.getQueryParameter("bitrate")?.takeIf { it.isNotBlank() }?.let { etBitrate.setText(it) }
        uri.getQueryParameter("name")?.takeIf { it.isNotBlank() }?.let { reporterName = it }

        savePrefs()
        showReporter()
        Toast.makeText(this, "האפליקציה הוגדרה: $reporterName", Toast.LENGTH_LONG).show()
    }

    private fun loadPrefs() {
        val p = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        etHost.setText(p.getString("host", "satview.ddns.net"))
        etPort.setText(p.getString("port", BONDING_PORT.toString()))
        etBitrate.setText(p.getString("bitrate", "3500"))
        etStreamId.setText(p.getString("sid", "publish:app1"))
        reporterName = p.getString("name", "") ?: ""
        showReporter()
    }

    private fun savePrefs() {
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("host", etHost.text.toString().trim())
            .putString("port", etPort.text.toString().trim())
            .putString("bitrate", etBitrate.text.toString().trim())
            .putString("sid", etStreamId.text.toString().trim())
            .putString("name", reporterName)
            .apply()
    }

    private fun showReporter() {
        val slot = etStreamId.text.toString().substringAfter(':', "").uppercase()
        tvReporter.text = when {
            reporterName.isNotBlank() && slot.isNotBlank() -> "כתב: $reporterName · $slot"
            reporterName.isNotBlank() -> "כתב: $reporterName"
            slot.isNotBlank() -> "משבצת: $slot"
            else -> "לא הוגדר · פתח את לינק ההגדרה"
        }
    }

    /* ---------- permissions / camera ---------- */

    private fun neededPermissions(): Array<String> {
        val list = mutableListOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            list.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        return list.toTypedArray()
    }

    private fun hasPermissions() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED &&
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun initCamera() {
        if (camera == null) camera = SrtCamera2(openGlView, this)
    }

    /* ---------- streaming ---------- */

    private fun startAll() {
        val cam = camera ?: return
        savePrefs()
        showReporter()

        val host = etHost.text.toString().trim()
        val port = etPort.text.toString().trim().toIntOrNull() ?: DIRECT_PORT
        val bitrateKbps = etBitrate.text.toString().trim().toIntOrNull() ?: 3500
        val streamId = etStreamId.text.toString().trim().ifEmpty { "publish:app1" }

        // H265 (HEVC): ~40% better compression than H264 at the same quality
        try { cam.setVideoCodec(VideoCodec.H265) } catch (e: Exception) {}

        val ok = cam.prepareVideo(1920, 1080, 30, bitrateKbps * 1000, 2, 0) &&
                 cam.prepareAudio(160 * 1000, 48000, true)
        if (!ok) {
            Toast.makeText(this, "המכשיר לא תומך בהגדרות הקידוד", Toast.LENGTH_LONG).show()
            return
        }

        // DIRECT mode: RootEncoder straight to MediaMTX (no bonding). Default.
        if (port == DIRECT_PORT) {
            streaming = true
            srtStarted = true
            btnStart.text = getString(R.string.stop)
            setInputsEnabled(false)
            tvStatus.text = "מתחבר..."
            StreamService.start(this)
            cam.streamClient.setSocketType(SocketType.JAVA)
            cam.streamClient.setReTries(1000)
            // 1s SRT recovery window + bigger retransmit cache for clean video
            cam.streamClient.setLatency(1_000_000)
            try { cam.streamClient.resizeCache(600) } catch (e: Exception) {}
            cam.startStream("srt://$host:$port?streamid=$streamId")
            return
        }

        // BONDING mode (SRTLA) on port 5000.
        sender = SrtlaSender(LOCAL_SRT_PORT, host, port) { msg ->
            runOnUiThread { if (!srtStarted) tvStatus.text = msg }
        }.also { it.start() }

        networks = BondingNetworks(this) { name, network, available ->
            if (available) sender?.addNetwork(name, network)
            else sender?.removeNetwork(name)
        }.also { it.start() }

        streaming = true
        srtStarted = false
        btnStart.text = getString(R.string.stop)
        setInputsEnabled(false)
        tvStatus.text = "ממתין לבונדינג..."
        StreamService.start(this)

        val startedAt = System.currentTimeMillis()
        val waiter = object : Runnable {
            override fun run() {
                if (!streaming) return
                val ready = (sender?.registeredCount() ?: 0) > 0
                val timedOut = System.currentTimeMillis() - startedAt > 20000
                if (ready || timedOut) {
                    srtStarted = true
                    cam.streamClient.setSocketType(SocketType.JAVA)
                    cam.streamClient.setReTries(1000)
                    // Bonding protection layer: 2s SRT recovery window (lost
                    // packets get retransmitted over any link) + big cache
                    cam.streamClient.setLatency(2_000_000)
                    try { cam.streamClient.resizeCache(1000) } catch (e: Exception) {}
                    cam.startStream("srt://127.0.0.1:$LOCAL_SRT_PORT?streamid=$streamId")
                    ui.post(statusTicker)
                } else {
                    ui.postDelayed(this, 300)
                }
            }
        }
        ui.postDelayed(waiter, 800)
    }

    private fun stopAll() {
        ui.removeCallbacks(statusTicker)
        try { camera?.stopStream() } catch (e: Exception) {}
        networks?.stop(); networks = null
        sender?.stop(); sender = null
        streaming = false
        srtStarted = false
        StreamService.stop(this)
        btnStart.text = getString(R.string.start)
        setInputsEnabled(true)
        tvStatus.text = "נעצר"
    }

    private fun setInputsEnabled(enabled: Boolean) {
        etHost.isEnabled = enabled
        etPort.isEnabled = enabled
        etBitrate.isEnabled = enabled
        etStreamId.isEnabled = enabled
    }

    /* ---------- surface lifecycle (camera stays alive in background) ---------- */

    override fun surfaceCreated(holder: SurfaceHolder) {}

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        if (!hasPermissions()) return
        initCamera()
        val cam = camera ?: return
        if (streaming) {
            try { cam.replaceView(openGlView) } catch (e: Exception) {}
        } else {
            if (!cam.isOnPreview) cam.startPreview()
        }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        val cam = camera ?: return
        if (streaming) {
            try { cam.replaceView(applicationContext) } catch (e: Exception) {}
        } else {
            if (cam.isOnPreview) cam.stopPreview()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (streaming) stopAll()
    }

    /* ---------- ConnectChecker ---------- */

    override fun onConnectionStarted(url: String) {}

    override fun onConnectionSuccess() {
        runOnUiThread {
            tvStatus.text = "SRT מחובר - משדרים!"
            Toast.makeText(this, "SRT מחובר - משדרים!", Toast.LENGTH_SHORT).show()
        }
    }

    override fun onConnectionFailed(reason: String) {
        runOnUiThread { tvStatus.text = "שגיאת חיבור: $reason" }
        camera?.streamClient?.reTry(3000, reason, null)
    }

    override fun onNewBitrate(bitrate: Long) {}

    override fun onDisconnect() {
        runOnUiThread { tvStatus.text = "SRT מנותק" }
    }

    override fun onAuthError() {}
    override fun onAuthSuccess() {}
}
