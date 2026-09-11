package com.makr.inferno.vm

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile

/**
 * Remembers the SAF tree the user picked for `InfernoData`, so the root
 * disk can be opened straight out of it at start time instead of being
 * copied. Everything else (firmware, nvram, the SEP files — a few tens of
 * megabytes total) is small enough that SetupScreen just copies it in, the
 * simple way; the disk itself (tens of gigabytes nominal, single-digit
 * gigabytes real) is the one file worth not doubling on a phone that's
 * often the tighter side of the free-space line.
 *
 * A plain SharedPreferences string, not DataStore: one value, read
 * synchronously wherever a file path is being built, no reason for a Flow.
 */
object GuestUriStore {
    private const val PREFS = "inferno_guest_uri"
    private const val KEY_TREE = "infernoDataTree"

    fun setTree(context: Context, uri: Uri) {
        context.contentResolver.takePersistableUriPermission(
            uri,
            android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or
                android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
        prefs(context).edit().putString(KEY_TREE, uri.toString()).apply()
    }

    fun tree(context: Context): DocumentFile? {
        val stored = prefs(context).getString(KEY_TREE, null) ?: return null
        val uri = Uri.parse(stored)
        // The permission can outlive the document itself (folder moved,
        // SD card pulled) — DocumentFile.fromTreeUri never throws for
        // that, but the DocumentFile it returns stops resolving children.
        return DocumentFile.fromTreeUri(context, uri)
    }

    /** The root disk's document, whichever of the two names it goes by,
     *  directly under the picked InfernoData tree — never nested, matching
     *  where VMConfig.arguments() expects to find it. */
    fun rootDocument(context: Context): DocumentFile? {
        val root = tree(context) ?: return null
        return root.findFile("root.qcow2") ?: root.findFile("root")
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
