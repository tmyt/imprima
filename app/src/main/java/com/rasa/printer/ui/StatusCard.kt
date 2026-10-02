package com.rasa.printer.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.rasa.printer.R
import com.rasa.printer.printer.PrinterConfig
import com.rasa.printer.service.PrinterStatus
import com.rasa.printer.service.ServiceState

@Composable
fun StatusCard(
    status: PrinterStatus,
    config: PrinterConfig,
    onToggle: (Boolean) -> Unit,
    onCopy: (String) -> Unit,
    onHelp: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val mode = stringResource(
        if (config.compatibilityMode) R.string.ui_mode_compat_short else R.string.ui_mode_pdf_short,
    )
    val summary = when (status.state) {
        ServiceState.RUNNING -> stringResource(R.string.ui_summary_running, status.port, mode)
        ServiceState.STARTING -> stringResource(R.string.ui_summary_starting, mode)
        else -> stringResource(R.string.ui_summary_stopped, mode)
    }
    val checked = status.state == ServiceState.RUNNING || status.state == ServiceState.STARTING
    Card(modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    config.name,
                    style = MaterialTheme.typography.titleLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f).padding(end = 12.dp),
                )
                Switch(checked = checked, onCheckedChange = onToggle)
            }
            Text(
                summary,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (status.state == ServiceState.ERROR) {
                Text(
                    status.error?.let { stringResource(R.string.ui_state_error, it) }
                        ?: stringResource(R.string.ui_state_error_unknown),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }
            if (status.state == ServiceState.RUNNING) {
                if (status.addresses.isEmpty()) {
                    Text(stringResource(R.string.ui_no_addresses), style = MaterialTheme.typography.bodySmall)
                }
                status.addresses.forEach { addr ->
                    val url = "ipp://$addr:${status.port}${PrinterConfig.RESOURCE_PATH}"
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            url,
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                            modifier = Modifier.weight(1f),
                        )
                        IconButton(onClick = { onCopy(url) }) {
                            Icon(Icons.Filled.ContentCopy, stringResource(R.string.ui_copy_address))
                        }
                    }
                }
            }
            TextButton(onClick = onHelp) {
                Icon(Icons.AutoMirrored.Filled.HelpOutline, null)
                Text(stringResource(R.string.ui_how_to_connect), modifier = Modifier.padding(start = 8.dp))
            }
        }
    }
}
