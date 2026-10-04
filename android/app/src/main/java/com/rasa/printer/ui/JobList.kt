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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.BorderStroke
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Print
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
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
fun JobsHeader(
    count: Int,
    onOpenFolder: () -> Unit,
    onDeleteAll: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            stringResource(R.string.ui_jobs_title_count, count),
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.weight(1f),
        )
        Box {
            IconButton(onClick = { menuOpen = true }) {
                Icon(Icons.Filled.MoreVert, stringResource(R.string.ui_more_actions))
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.ui_open_in_files)) },
                    onClick = { menuOpen = false; onOpenFolder() },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.ui_delete_all)) },
                    enabled = count > 0,
                    onClick = { menuOpen = false; onDeleteAll() },
                )
            }
        }
    }
}

@Composable
fun JobList(
    jobs: List<PrintJob>,
    onOpen: (PrintJob) -> Unit,
    onShare: (PrintJob) -> Unit,
    onDelete: (PrintJob) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (jobs.isEmpty()) {
        Column(
            modifier.fillMaxSize().padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
        ) {
            Icon(
                Icons.Filled.Print,
                contentDescription = null,
                modifier = Modifier.size(64.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(stringResource(R.string.ui_jobs_empty_title), style = MaterialTheme.typography.titleMedium)
            Text(
                stringResource(R.string.ui_jobs_empty_hint),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
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

@Composable
private fun StateBadge(state: JobState) {
    val scheme = MaterialTheme.colorScheme
    val (bg, fg, border) = when (state) {
        JobState.PENDING -> Triple(scheme.tertiaryContainer, scheme.onTertiaryContainer, null)
        JobState.ABORTED, JobState.CANCELED ->
            Triple(scheme.errorContainer, scheme.onErrorContainer, null)
        else -> Triple(Color.Transparent, scheme.onSurfaceVariant, BorderStroke(1.dp, scheme.outline))
    }
    Surface(color = bg, contentColor = fg, shape = MaterialTheme.shapes.small, border = border) {
        Text(
            jobStateLabel(state),
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
        )
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
    val time = DateUtils.formatDateTime(
        context, job.createdAt,
        DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_TIME or DateUtils.FORMAT_ABBREV_MONTH,
    )
    val size = Formatter.formatShortFileSize(context, job.sizeBytes)
    val details = listOf(jobFormatLabel(job.format), size, time, job.userName)
        .filter { it.isNotBlank() }.joinToString(" · ")

    ListItem(
        modifier = Modifier.combinedClickable(
            onClick = { onOpen(job) },
            onLongClick = { menuOpen = true },
        ),
        headlineContent = {
            Text(
                job.name.ifBlank { stringResource(R.string.ui_job_n, job.id) },
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        },
        supportingContent = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(details, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (job.state != JobState.COMPLETED) StateBadge(job.state)
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
