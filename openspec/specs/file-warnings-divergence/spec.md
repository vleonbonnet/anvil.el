# Specification: file-warnings-divergence

## Purpose

Define the observable `:warnings` contract that every mutating
`file-*` MCP tool SHALL honor so that an AI caller can detect when
its disk write may be colliding with a live Emacs buffer's unsaved
state, without the write itself being silently refused.

## Requirements

### Requirement: Every mutating `file-*` tool MUST surface a `:warnings` list in its result

Every tool that writes to disk and is registered under the `file-*`
name family (such as `file-read`, `file-replace-string`,
`file-replace-regexp`, `file-insert-at-line`, `file-delete-lines`,
`file-append`, `file-prepend`, `file-batch`, `file-ensure-import`)
SHALL return a plist that includes a `:warnings` field. The field
SHALL be a list, possibly empty. An empty list indicates that no
disk/buffer divergence was detected for the target file at the time
of the call and that any post-write buffer resync (see the resync
requirement below) completed without incident. A non-empty list
indicates detected divergence or a resync incident, with at least
one entry identifying the condition (for example buffer-newer,
disk-newer, both-modified, unknown, or a not-resynced report).

#### Scenario: External edit on an open buffer surfaces a warning

- **GIVEN** a file visited by an Emacs buffer with no unsaved changes
- **AND** the file on disk is modified externally so that its mtime
  is newer than the buffer's recorded modtime
- **WHEN** a client calls any mutating `file-*` tool on that file
- **THEN** the tool's result plist includes a non-empty `:warnings`
  list whose contents name the detected divergence kind (here,
  disk-newer)

### Requirement: A non-empty `:warnings` list MUST NOT cause the tool to refuse the write

The `file-*` tool family SHALL honor a disk-first contract: reporting
a divergence warning SHALL NOT prevent the write from completing. The
disk content after the call SHALL reflect what the tool was asked to
produce, regardless of the warnings. Refusal on divergence is the
responsibility of the separate `buffer-save` tool and is out of scope
here.

#### Scenario: Write proceeds despite divergence warning

- **GIVEN** a file that has divergence between disk and a visited
  buffer (for example both have been modified since the last sync)
- **WHEN** a client calls `file-replace-string` on that file
- **THEN** the disk content reflects the replacement
- **AND** the returned plist still includes a non-empty `:warnings`
  entry describing the divergence

### Requirement: After a write, a clean visiting buffer MUST be resynced to disk

When a mutating `file-*` tool has written a file that is visited by
a buffer with no unsaved modifications, the tool SHALL revert that
buffer so its content, modified flag, and recorded modtime match the
new disk state before the tool returns. A buffer with unsaved
modifications SHALL NOT be reverted; instead the result's
`:warnings` SHALL include an entry reporting that the buffer was not
resynced. A buffer whose recorded modtime is the intentional-stale
sentinel (zero) SHALL NOT be reverted and SHALL NOT produce a resync
warning. A failed revert SHALL be reported via `:warnings`, not by
signaling an error, because the disk write has already succeeded.
The whole behavior MAY be disabled via a user option
(`anvil-disk-resync-after-write`), restoring warn-only semantics.

#### Scenario: Successive edits to an open file need no manual revert

- **GIVEN** a file visited by an Emacs buffer with no unsaved changes
- **WHEN** a client calls `file-replace-string` on that file twice in
  a row
- **THEN** after each call the visiting buffer's content equals the
  disk content
- **AND** both calls return an empty `:warnings` list

#### Scenario: Unsaved user edits survive the write

- **GIVEN** a file visited by an Emacs buffer with unsaved changes
- **WHEN** a client calls a mutating `file-*` tool on that file
- **THEN** the disk content reflects the tool's edit
- **AND** the buffer still contains the unsaved user changes
- **AND** the returned `:warnings` reports both the divergence and
  that the buffer was not resynced

## Non-goals

- The `buffer-*` tool family (`buffer-read`, `buffer-save`,
  `buffer-list-modified`) has its own semantics and is out of scope.
  In particular `buffer-save` MAY refuse to write on `disk-newer` or
  `both-modified`; that behavior is covered by a separate spec.
- This spec does not fix the exact string labels, symbols, or plist
  shape of the individual warning entries — only that the `:warnings`
  field exists, is a list, and is empty iff no divergence was
  detected.
- Non-mutating observability tools (for example `file-outline`,
  `code-extract-pattern`) that do not write to disk are not required
  to surface `:warnings`.
- Detection of divergence on filesystems with very coarse mtime
  resolution (for example FAT 2-second precision) MAY be approximate;
  this spec only requires best-effort detection using the ambient
  `file-attributes` / `visited-file-modtime` signals.
