package com.rasa.printer.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.rasa.printer.R
import com.rasa.printer.printer.PrinterConfig

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectHelpSheet(
    address: String?,
    port: Int,
    compatibilityMode: Boolean,
    onDismiss: () -> Unit,
) {
    val addr = address ?: stringResource(R.string.ui_help_addr_placeholder)
    val ipp = "ipp://$addr:$port${PrinterConfig.RESOURCE_PATH}"
    val http = "http://$addr:$port${PrinterConfig.RESOURCE_PATH}"
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .padding(horizontal = 24.dp)
                .padding(bottom = 24.dp),
        ) {
            Text(stringResource(R.string.ui_how_to_connect), style = MaterialTheme.typography.titleLarge)
            Section(R.string.ui_help_macos, stringResource(R.string.ui_help_macos_body, ipp))
            Section(
                R.string.ui_help_linux,
                stringResource(R.string.ui_help_linux_body),
                code = "lpadmin -p rasa -E -v $ipp -m everywhere",
            )
            Section(R.string.ui_help_windows, stringResource(R.string.ui_help_windows_body), code = http)
            Section(
                R.string.ui_help_ios,
                stringResource(
                    if (compatibilityMode) R.string.ui_help_ios_body else R.string.ui_help_ios_switch,
                ),
            )
        }
    }
}

@Composable
private fun Section(title: Int, body: String, code: String? = null) {
    Text(
        stringResource(title),
        style = MaterialTheme.typography.titleSmall,
        modifier = Modifier.padding(top = 16.dp),
    )
    Text(body, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.fillMaxWidth())
    if (code != null) {
        Text(
            code,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}
