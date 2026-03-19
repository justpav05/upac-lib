/// Числовые коды ошибок для C boundary.
pub const ErrorCode = enum(i32) {
    ok = 0,

    // Общие
    unexpected = 1,
    out_of_memory = 2,
    invalid_path = 3,
    file_not_found = 4,

    // Lock
    lock_would_block = 10,

    // Database
    db_missing_field = 20,
    db_missing_section = 21,
    db_invalid_entry = 22,
    db_parse_error = 23,

    // Installer
    install_copy_failed = 30,
    install_link_failed = 31,
    install_perm_failed = 32,
    install_reg_failed = 33,

    // OStree
    ostree_repo_open = 40,
    ostree_commit = 41,
    ostree_diff = 42,
    ostree_rollback = 43,
    ostree_no_parent = 44,

    // Init
    already_initialized = 50,
    create_dir_failed = 51,
    ostree_init_failed = 52,
};

/// Конвертирует anyerror в ErrorCode.
pub fn fromError(err: anyerror) ErrorCode {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.FileNotFound => .file_not_found,
        error.WouldBlock => .lock_would_block,
        error.MissingField => .db_missing_field,
        error.MissingMetaSection, error.MissingFilesSection => .db_missing_section,
        error.InvalidIndexEntry, error.InvalidFilePath => .db_invalid_entry,
        error.AlreadyInitialized => .already_initialized,
        error.CreateDirFailed => .create_dir_failed,
        error.OstreeInitFailed => .ostree_init_failed,
        error.RepoOpenFailed => .ostree_repo_open,
        error.CommitFailed => .ostree_commit,
        error.DiffFailed => .ostree_diff,
        error.RollbackFailed => .ostree_rollback,
        error.NoPreviousCommit => .ostree_no_parent,
        else => .unexpected,
    };
}
