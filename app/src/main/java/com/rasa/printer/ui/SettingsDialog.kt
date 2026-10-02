package com.rasa.printer.ui

import androidx.compose.foundation.layout.Column
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.rasa.printer.R
import com.rasa.printer.printer.PrinterConfig

@Composable
fun SettingsDialog(
    config: PrinterConfig,
    onDismiss: () -> Unit,
    onSave: (PrinterConfig) -> Unit,
) {
    var name by remember { mutableStateOf(config.name) }
    var portText by remember { mutableStateOf(config.port.toString()) }
    var location by remember { mutableStateOf(config.location) }

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
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                )
                OutlinedTextField(
                    value = location,
                    onValueChange = { location = it },
                    label = { Text(stringResource(R.string.ui_field_location)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                )
                Text(
                    text = stringResource(R.string.ui_field_uuid),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 16.dp),
                )
                Text(
                    text = config.uuid,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = portValid && nameValid,
                onClick = {
                    onSave(config.copy(name = name.trim(), port = port!!, location = location.trim()))
                },
            ) { Text(stringResource(R.string.ui_save)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.ui_cancel)) }
        },
    )
}
