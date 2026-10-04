package dev.utatane.imprima.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.utatane.imprima.R
import dev.utatane.imprima.printer.PrinterConfig
import dev.utatane.imprima.service.PrinterStatus
import dev.utatane.imprima.service.ServiceState

@Composable
fun StatusCard(
    status: PrinterStatus,
    config: PrinterConfig,
    onToggle: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val mode = stringResource(
        if (config.compatibilityMode) R.string.ui_mode_compat_short else R.string.ui_mode_pdf_short,
    )
    val summary = when (status.state) {
        ServiceState.RUNNING -> stringResource(R.string.ui_summary_running, mode)
        ServiceState.STARTING -> stringResource(R.string.ui_state_starting)
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
        }
    }
}
