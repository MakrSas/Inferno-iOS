package com.makr.inferno.vm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.makr.inferno.MainActivity
import com.makr.inferno.R

/**
 * Justifies to the system why this process should keep running once the
 * app is backgrounded — nothing here talks to the emulator directly.
 * `QemuBridge` is a process-wide singleton and its native thread keeps
 * running for as long as the process does regardless of this service; the
 * service's only job is to be a foreground service with a notification, so
 * the OS doesn't treat a backgrounded Inferno as an ordinary idle app and
 * kill it. See ANDROID-PORT.md ("Фоновая работа") — this is the one iOS has
 * no equivalent of at all, since UIApplication background execution is far
 * more restricted than a guest actually needs.
 */
class VmService : Service() {
    companion object {
        private const val CHANNEL_ID = "vm_running"
        private const val NOTIFICATION_ID = 1

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, VmService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, VmService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Гость Inferno", NotificationManager.IMPORTANCE_LOW),
            )
        }
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.app_name))
            .setContentText("Гость работает в фоне")
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentIntent(openApp)
            .setOngoing(true)
            .build()
    }
}
