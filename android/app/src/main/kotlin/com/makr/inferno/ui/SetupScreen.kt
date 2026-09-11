@file:OptIn(ExperimentalMaterial3Api::class)

package com.makr.inferno.ui

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.InsertDriveFile
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.documentfile.provider.DocumentFile
import com.makr.inferno.R
import com.makr.inferno.vm.VMConfig
import com.makr.inferno.vm.VMModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Shown until the guest images are present in the app's own storage.
 *
 * iOS gets this for free from the Files app once a folder exists on disk —
 * a person just drags InfernoData in. Android's scoped storage has no
 * equivalent free lunch: an app-specific external directory isn't a drop
 * target for a stock file manager the way it is in iOS, so this screen goes
 * through the Storage Access Framework instead and copies what comes back,
 * once, into `VMConfig.guestFilesRoot`.
 */
@Composable
fun SetupScreen(model: VMModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var copying by remember { mutableStateOf<String?>(null) }

    val pickFolder = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        val tree = DocumentFile.fromTreeUri(context, uri) ?: return@rememberLauncherForActivityResult
        scope.launch {
            copying = tree.name ?: "InfernoData"
            withContext(Dispatchers.IO) {
                copyTreeInto(context, tree, File(VMConfig.guestFilesRoot(context), "InfernoData"))
            }
            copying = null
            model.refreshFiles()
        }
    }

    val pickSepRom = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            copying = "AppleSEPROM-Cebu-B1"
            withContext(Dispatchers.IO) {
                context.contentResolver.openInputStream(uri)?.use { input ->
                    VMConfig.sepROM(context).outputStream().use { output -> input.copyTo(output) }
                }
            }
            copying = null
            model.refreshFiles()
        }
    }

    Scaffold(topBar = { TopAppBar(title = { Text(stringResource(R.string.setup_title)) }) }) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                text = stringResource(R.string.setup_instructions),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            copying?.let { name ->
                ListItem(
                    leadingContent = { CircularProgressIndicator(modifier = Modifier.size(24.dp)) },
                    headlineContent = { Text(stringResource(R.string.setup_copying, name)) },
                )
            }

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = { pickFolder.launch(null) },
                    enabled = copying == null,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Filled.FolderOpen, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.setup_pick_folder))
                }
                OutlinedButton(
                    onClick = { pickSepRom.launch(arrayOf("*/*")) },
                    enabled = copying == null,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Filled.InsertDriveFile, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.setup_pick_seprom))
                }
            }

            Text(
                text = stringResource(R.string.setup_missing_header),
                style = MaterialTheme.typography.titleSmall,
            )
            LazyColumn(
                modifier = Modifier.weight(1f, fill = false),
                contentPadding = PaddingValues(vertical = 4.dp),
            ) {
                items(model.missing) { label ->
                    ListItem(
                        leadingContent = {
                            Icon(
                                Icons.Filled.ErrorOutline,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.error,
                            )
                        },
                        headlineContent = { Text(label) },
                    )
                }
            }

            OutlinedButton(onClick = { model.refreshFiles() }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Filled.Refresh, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.setup_recheck))
            }
        }
    }
}

/** Recursively copies a picked SAF tree into `destination`, preserving the
 *  relative layout the guest images ship in (InfernoData/Restore/...). */
private fun copyTreeInto(context: Context, source: DocumentFile, destination: File) {
    destination.mkdirs()
    for (child in source.listFiles()) {
        val name = child.name ?: continue
        val target = File(destination, name)
        if (child.isDirectory) {
            copyTreeInto(context, child, target)
        } else {
            context.contentResolver.openInputStream(child.uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
        }
    }
}
