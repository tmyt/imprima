package com.rasa.printer.ui

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rasa.printer.R
import com.rasa.printer.printer.PrintJob
import com.rasa.printer.printer.PrinterConfig
import com.rasa.printer.service.PrinterStatus
import com.rasa.printer.service.ServiceState
import kotlinx.coroutines.launch

private const val FILE_PROVIDER_AUTHORITY = "com.rasa.printer.fileprovider"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(viewModel: MainViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val status by viewModel.status.collectAsStateWithLifecycle()
    val config by viewModel.config.collectAsStateWithLifecycle()
    val jobs by viewModel.jobs.collectAsStateWithLifecycle()

    val snackbar = remember { SnackbarHostState() }
    var showSettings by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<PrintJob?>(null) }

    val noApp = stringResource(R.string.ui_no_app_to_open)
    val noFile = stringResource(R.string.ui_no_file)
    val copiedMsg = stringResource(R.string.ui_copied)

    // Start regardless of the permission result; the service works without a visible notification.
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { viewModel.start() }

    fun onToggle(on: Boolean) {
        if (!on) {
            viewModel.stop()
            return
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            viewModel.start()
        }
    }

    fun launchJobIntent(job: PrintJob, share: Boolean) {
        val file = job.file?.takeIf { it.exists() }
        if (file == null) {
            scope.launch { snackbar.showSnackbar(noFile) }
            return
        }
        val uri = FileProvider.getUriForFile(context, FILE_PROVIDER_AUTHORITY, file)
        val intent = if (share) {
            Intent.createChooser(
                Intent(Intent.ACTION_SEND).apply {
                    type = job.format
                    putExtra(Intent.EXTRA_STREAM, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                },
                null,
            )
        } else {
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, job.format)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        }
        try {
            context.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            scope.launch { snackbar.showSnackbar(noApp) }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.ui_app_title)) },
                actions = {
                    IconButton(onClick = { showSettings = true }) {
                        Icon(Icons.Filled.Settings, stringResource(R.string.ui_settings))
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Column(Modifier.padding(padding)) {
            StatusCard(
                status = status,
                config = config,
                onToggle = ::onToggle,
                onCopy = { text ->
                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    cm.setPrimaryClip(ClipData.newPlainText("printer address", text))
                    // Android 13+ shows its own confirmation.
                    if (Build.VERSION.SDK_INT < 33) scope.launch { snackbar.showSnackbar(copiedMsg) }
                },
                modifier = Modifier.padding(16.dp),
            )
            Text(
                stringResource(R.string.ui_jobs_title),
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
            JobList(
                jobs = jobs,
                onOpen = { launchJobIntent(it, share = false) },
                onShare = { launchJobIntent(it, share = true) },
                onDelete = { pendingDelete = it },
            )
        }
    }

    if (showSettings) {
        SettingsDialog(
            config = config,
            onDismiss = { showSettings = false },
            onSave = { viewModel.save(it); showSettings = false },
        )
    }

    pendingDelete?.let { job ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(stringResource(R.string.ui_delete_title)) },
            text = { Text(stringResource(R.string.ui_delete_message, job.name)) },
            confirmButton = {
                TextButton(onClick = { viewModel.delete(job.id); pendingDelete = null }) {
                    Text(stringResource(R.string.ui_delete))
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) {
                    Text(stringResource(R.string.ui_cancel))
                }
            },
        )
    }
}

@Composable
private fun StatusCard(
    status: PrinterStatus,
    config: PrinterConfig,
    onToggle: (Boolean) -> Unit,
    onCopy: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val stateText = when (status.state) {
        ServiceState.STOPPED -> stringResource(R.string.ui_state_stopped)
        ServiceState.STARTING -> stringResource(R.string.ui_state_starting)
        ServiceState.RUNNING -> stringResource(R.string.ui_state_running)
        ServiceState.ERROR -> status.error?.let { stringResource(R.string.ui_state_error, it) }
            ?: stringResource(R.string.ui_state_error_unknown)
    }
    val checked = status.state == ServiceState.RUNNING || status.state == ServiceState.STARTING
    Card(modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(config.name, style = MaterialTheme.typography.titleLarge)
                    Text(
                        stateText,
                        style = MaterialTheme.typography.bodyLarge,
                        color = if (status.state == ServiceState.ERROR) {
                            MaterialTheme.colorScheme.error
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                    )
                }
                Switch(checked = checked, onCheckedChange = onToggle)
            }
            if (status.state == ServiceState.RUNNING) {
                if (status.addresses.isEmpty()) {
                    Text(stringResource(R.string.ui_no_addresses), style = MaterialTheme.typography.bodyMedium)
                }
                status.addresses.forEach { addr ->
                    val url = "ipp://$addr:${status.port}${PrinterConfig.RESOURCE_PATH}"
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            url,
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.weight(1f),
                        )
                        IconButton(onClick = { onCopy(url) }) {
                            Icon(Icons.Filled.ContentCopy, stringResource(R.string.ui_copy_address))
                        }
                    }
                }
                Text(
                    stringResource(R.string.ui_hint_add_printer),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
