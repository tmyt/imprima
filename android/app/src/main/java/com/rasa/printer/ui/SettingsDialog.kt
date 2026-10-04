package com.rasa.printer.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.RadioButton
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.Alignment
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.material.icons.Icons
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.rasa.printer.R
import com.rasa.printer.printer.PrinterConfig

@Composable
fun SettingsDialog(
    config: PrinterConfig,
    addresses: List<String>,
    onDismiss: () -> Unit,
    onSave: (PrinterConfig) -> Unit,
) {
    var name by remember { mutableStateOf(config.name) }
    var portText by remember { mutableStateOf(config.port.toString()) }
    var location by remember { mutableStateOf(config.location) }

    val context = LocalContext.current
    val version = remember {
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }
            .getOrNull() ?: "?"
    }
    var compat by remember { mutableStateOf(config.compatibilityMode) }

    val port = portText.toIntOrNull()
    val portValid = port != null && port in 1024..65535
    val nameValid = name.isNotBlank()

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.ui_settings_title)) },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
            ) {
                SectionLabel(R.string.ui_section_printer, first = true)
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text(stringResource(R.string.ui_field_name)) },
                    singleLine = true,
                    isError = !nameValid,
                    supportingText = if (!nameValid) {
                        { Text(stringResource(R.string.ui_field_name_error)) }
                    } else null,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = location,
                    onValueChange = { location = it },
                    label = { Text(stringResource(R.string.ui_field_location)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                )
                SectionLabel(R.string.ui_section_network)
                OutlinedTextField(
                    value = portText,
                    onValueChange = { v -> portText = v.filter { it.isDigit() }.take(5) },
                    label = { Text(stringResource(R.string.ui_field_port)) },
                    singleLine = true,
                    isError = !portValid,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    supportingText = {
                        Text(
                            stringResource(
                                if (portValid) R.string.ui_field_port_support else R.string.ui_field_port_error,
                            ),
                        )
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    stringResource(R.string.ui_current_addresses),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 12.dp),
                )
                if (addresses.isEmpty()) {
                    Text(
                        stringResource(R.string.ui_not_connected),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
                addresses.forEach { addr ->
                    Text(
                        addr,
                        style = MaterialTheme.typography.bodyMedium,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier.padding(vertical = 4.dp),
                    )
                }
                SectionLabel(R.string.ui_section_mode)
                Column(Modifier.selectableGroup()) {
                    ModeOption(
                        selected = !compat,
                        title = R.string.ui_mode_pdf_title,
                        description = R.string.ui_mode_pdf_desc,
                        onClick = { compat = false },
                    )
                    ModeOption(
                        selected = compat,
                        title = R.string.ui_mode_compat_title,
                        description = R.string.ui_mode_compat_desc,
                        onClick = { compat = true },
                    )
                }
                SectionLabel(R.string.ui_section_about)
                Text(
                    text = stringResource(R.string.ui_field_uuid),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    text = config.uuid,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    text = stringResource(R.string.ui_app_version, version),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = portValid && nameValid,
                onClick = {
                    onSave(config.copy(name = name.trim(), port = port!!, location = location.trim(), compatibilityMode = compat))
                },
            ) { Text(stringResource(R.string.ui_save)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.ui_cancel)) }
        },
    )
}

@Composable
private fun ModeOption(
    selected: Boolean,
    title: Int,
    description: Int,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .selectable(selected = selected, onClick = onClick, role = Role.RadioButton)
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.Top,
    ) {
        RadioButton(selected = selected, onClick = null, modifier = Modifier.padding(end = 12.dp, top = 2.dp))
        Column {
            Text(stringResource(title), style = MaterialTheme.typography.bodyLarge)
            Text(
                stringResource(description),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SectionLabel(title: Int, first: Boolean = false) {
    Text(
        stringResource(title),
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = if (first) 0.dp else 20.dp, bottom = 8.dp),
    )
}
