package com.rasa.printer.ui

import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AssistChip
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.rasa.printer.R
import com.rasa.printer.printer.JobState
import com.rasa.printer.printer.PrintJob

@Composable
fun jobFormatLabel(mime: String): String = when (mime.lowercase().substringBefore(';').trim()) {
    "application/pdf" -> stringResource(R.string.ui_format_pdf)
    "image/pwg-raster" -> stringResource(R.string.ui_format_pwg)
    "image/urf" -> stringResource(R.string.ui_format_urf)
    "image/jpeg" -> stringResource(R.string.ui_format_jpeg)
    "image/png" -> stringResource(R.string.ui_format_png)
    else -> mime
}

@Composable
fun jobStateLabel(state: JobState): String = stringResource(
    when (state) {
        JobState.PENDING -> R.string.ui_state_job_pending
        JobState.PENDING_HELD -> R.string.ui_state_job_held
        JobState.PROCESSING -> R.string.ui_state_job_processing
        JobState.PROCESSING_STOPPED -> R.string.ui_state_job_stopped
        JobState.CANCELED -> R.string.ui_state_job_canceled
        JobState.ABORTED -> R.string.ui_state_job_aborted
        JobState.COMPLETED -> R.string.ui_state_job_completed
    },
)

@Composable
fun JobList(
    jobs: List<PrintJob>,
    onOpen: (PrintJob) -> Unit,
    onShare: (PrintJob) -> Unit,
    onDelete: (PrintJob) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (jobs.isEmpty()) {
        Box(modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
            Text(
                stringResource(R.string.ui_jobs_empty),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        return
    }
    LazyColumn(modifier.fillMaxSize()) {
        items(jobs, key = { it.id }) { job ->
            JobRow(job, onOpen, onShare, onDelete)
            HorizontalDivider()
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun JobRow(
    job: PrintJob,
    onOpen: (PrintJob) -> Unit,
    onShare: (PrintJob) -> Unit,
    onDelete: (PrintJob) -> Unit,
) {
    val context = LocalContext.current
    var menuOpen by remember { mutableStateOf(false) }
    val time = DateUtils.getRelativeTimeSpanString(
        job.createdAt, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS,
    ).toString()
    val size = Formatter.formatShortFileSize(context, job.sizeBytes)
    val format = jobFormatLabel(job.format)

    ListItem(
        modifier = Modifier.combinedClickable(
            onClick = { onOpen(job) },
            onLongClick = { menuOpen = true },
        ),
        headlineContent = {
            Text(
                job.name.ifBlank { stringResource(R.string.ui_job_unnamed) },
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        },
        supportingContent = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(stringResource(R.string.ui_job_by, job.userName, time))
                if (job.uri != null) {
                    Text(
                        stringResource(R.string.ui_job_saved_in),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.ui_job_meta, format, size))
                    AssistChip(onClick = {}, label = { Text(jobStateLabel(job.state)) })
                }
            }
        },
        trailingContent = {
            Box {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(Icons.Filled.MoreVert, stringResource(R.string.ui_more_actions))
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.ui_share)) },
                        leadingIcon = { Icon(Icons.Filled.Share, null) },
                        onClick = { menuOpen = false; onShare(job) },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.ui_delete)) },
                        leadingIcon = { Icon(Icons.Filled.Delete, null) },
                        onClick = { menuOpen = false; onDelete(job) },
                    )
                }
            }
        },
    )
}
