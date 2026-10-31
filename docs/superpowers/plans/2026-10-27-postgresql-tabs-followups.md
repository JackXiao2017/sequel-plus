# PostgreSQL tabs — follow-ups

Deferred findings from the tabs plan's per-task and final reviews (none block day-to-day use).

- T1: visibility(default) on SPWindowController changes exported symbols — note in final review
- T1: redundant isKindOfClass || respondsToSelector in didDrop; redundant inner check in tooltip branch
- T1: updateTabBar not run when switching between two non-MySQL tabs (T3/T4 tab colours); validateMenuItem: YES for window items on non-MySQL tab (T2)
- T1: cell move assumes no drag placeholders in cells (skip move while PSMTabDragAssistant isDragging); drop tests leave target windows open (orderOut only); no-source-window drop leaves source observer (documented)
- T2: only first background alert kept; SSH prompt window captured before mid-switch drag; tests: close-disconnect trivially sync, no YES assert for toggleConsole:
- T2: pre-existing MySQL SPRuleFilterController _resize UAF if tab closed <0.2 s after creation — final review
- T2: Hide Console title branch untested; namesake label without currentDatabase shows bare name
- T3: insertion call site untested with key unset; PG items lack MySQL tooltips; SPToolbarTransferItem files in Postgres group; can disabled Transfer be dragged from Customize palette (owner visual check)
- T4: replaceTabDocument: silent no-op if no window controller/tab not found (assert/log); R8 tests call helper not addConnectionToDocument; connect steals selection if user switched tabs meanwhile; pre-existing SPRuleFilterController _resize crash could hit a PG connect within ~0.2 s of opening a tab
- Final: F6 test prefs guard doesn't structurally cover nib-decoded autosave names (no observed writes); Postgres tabs share the window's undo manager.
