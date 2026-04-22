pub const Operation = enum { install, uninstall, rollback, init, diff, list };

// A listing of all possible return codes used to signal success or specific runtime errors
pub const ErrorCode = enum(i32) {
    ok = 0,

    // --- General Errors (0 - 19) ---
    unexpected = 1,
    out_of_memory = 2,
    file_not_found = 3,
    permission_denied = 4,
    invalid_path = 5,
    no_space_left = 6,
    abi_mismatch = 7,

    tread_error = 9,
    lock_would_block = 10,
    allocz_failed = 11,
    cancelled = 12,
    max_retries_exceeded = 13,
    read_failed = 14,
    write_failed = 15,

    // --- Database & Index Errors (20 - 29) ---
    db_missing_field = 20,
    db_missing_section = 21,
    db_invalid_entry = 22,
    db_parse_error = 23,
    db_write_database_failed = 24,
    db_malformed_meta = 25,
    db_malformed_files = 26,
    idx_malformed_entry = 27,

    // --- Installer Errors (30 - 39) ---
    install_already_installed = 30,
    install_package_path_not_found = 31,
    install_collect_file_checksum_failed = 32,
    install_checkout_failed = 33,
    install_cancelled = 34,
    install_max_retries_exceeded = 35,
    install_check_space_failed = 36,
    install_make_failed = 37,

    // --- Uninstaller Errors (40 - 49) ---
    uninstall_not_found = 40,
    uninstall_failed = 41,
    uninstall_file_map_corrupted = 42,
    uninstall_staging_not_cleaned = 43,

    // --- OSTree, Repo & FSM Errors (50 - 59 & 65 - 66) ---
    ostree_repo_open_failed = 50,
    ostree_repo_transaction_failed = 51,
    ostree_commit = 52,
    ostree_diff = 53,
    ostree_rollback = 54,
    ostree_no_parent = 55,
    ostree_staging_failed = 56,
    ostree_swap_failed = 57,
    ostree_commit_not_found = 58,
    ostree_cleanup_failed = 59,
    ostree_repo_write_failed = 65,
    ostree_mtree_insert_failed = 66,

    // --- Init Errors (60 - 64 & 67 - 68) ---
    already_initialized = 60,
    create_dir_failed = 61,
    not_a_directory = 62,
    ostree_init_failed = 63,
    directory_not_empty = 64,
    init_prefix_not_found = 67,
    init_additional_prefix_not_found = 68,

    // --- File Checksum/FSM Errors (70+) ---
    file_checksum_failed = 70,
    file_already_exists = 71,
};

// A mapper function that translates internal Zig errors (anyerror) into ErrorCode values understandable by the external interface
pub fn fromError(err: anyerror, operation: Operation) ErrorCode {
    const specific: ?ErrorCode = switch (operation) {
        .init => switch (err) {
            error.RootNotFound => .file_not_found,
            error.AlreadyInitialized => .already_initialized,
            error.CreateDirFailed => .create_dir_failed,
            error.NotADirectory => .not_a_directory,
            error.DirectoryNotEmpty => .directory_not_empty,
            error.OstreeInitFailed => .ostree_init_failed,
            error.PrefixNotFound => .init_prefix_not_found,
            error.AdditionalPrefixNotFound => .init_additional_prefix_not_found,
            else => null,
        },
        .install => switch (err) {
            error.AlreadyInstalled => .install_already_installed,
            error.PackagePathNotFound => .install_package_path_not_found,
            error.CollectFileChecksumsFailed => .install_collect_file_checksum_failed,
            error.CheckoutFailed => .install_checkout_failed,
            error.Cancelled => .install_cancelled,
            error.MaxRetriesExceeded => .install_max_retries_exceeded,
            error.CheckSpaceFailed => .install_check_space_failed,
            error.MakeFailed => .install_make_failed,
            error.RepoOpenFailed => .ostree_repo_open_failed,
            error.RepoTransactionFailed => .ostree_repo_transaction_failed,
            else => null,
        },
        .uninstall => switch (err) {
            error.PackageNotFound => .uninstall_not_found,
            error.UninstallFailed => .uninstall_failed,
            error.MissingRepository, error.RepoOpenFailed => .ostree_repo_open_failed,
            error.FileMapCorrupted => .uninstall_file_map_corrupted,
            error.StagingNotCleaned => .uninstall_staging_not_cleaned,
            error.RepoTransactionFailed => .ostree_repo_transaction_failed,
            error.CheckoutFailed => .install_checkout_failed,
            else => null,
        },
        .rollback => switch (err) {
            error.PathNotFound => .invalid_path,
            error.RepoOpenFailed => .ostree_repo_open_failed,
            error.RepoTransactionFailed => .ostree_repo_transaction_failed,
            error.RollbackFailed => .ostree_rollback,
            error.NoPreviousCommit => .ostree_no_parent,
            error.CommitNotFound => .ostree_commit_not_found,
            error.StagingFailed => .ostree_staging_failed,
            error.SwapFailed => .ostree_swap_failed,
            error.CleanupFailed => .ostree_cleanup_failed,
            else => null,
        },
        .diff => switch (err) {
            error.PathInvalid => .invalid_path,
            error.RepoOpenFailed => .ostree_repo_open_failed,
            error.CommitNotFound => .ostree_commit_not_found,
            error.DiffFailed => .ostree_diff,
            error.StagingFailed => .ostree_staging_failed,
            error.CleanupFailed => .ostree_cleanup_failed,
            error.FileNotFound => .file_not_found,
            error.AllocZPrintFailed => .out_of_memory,
            error.Cancelled => .cancelled,
            else => null,
        },
        else => null,
    };

    if (specific) |code| return code;

    return switch (err) {
        error.OutOfMemory, error.AllocZFailed => .out_of_memory,
        error.InvalidPath, error.BadPathName, error.RepoPathNotFound, error.PathNotFound => .invalid_path,
        error.FileNotFound => .file_not_found,
        error.AccessDenied => .permission_denied,
        error.AbiMismatch => .abi_mismatch,
        error.WouldBlock => .lock_would_block,
        error.ErrorTreadError => .tread_error,
        error.NotEnoughSpace => .no_space_left,
        error.Cancelled => .cancelled,
        error.MaxRetriesExceeded => .max_retries_exceeded,

        error.MissingField => .db_missing_field,
        error.MissingSection => .db_missing_section,
        error.InvalidEntry => .db_invalid_entry,
        error.ParseError => .db_parse_error,
        error.WriteDatabaseFailed => .db_write_database_failed,
        error.MalformedMeta => .db_malformed_meta,
        error.MalformedFiles => .db_malformed_files,

        error.MalformedEntry => .idx_malformed_entry,
        error.ReadFailed => .read_failed,
        error.WriteError, error.WriteFailed => .write_failed,
        error.ChecksumFailed => .file_checksum_failed,
        error.FileAlreadyExists => .file_already_exists,
        error.RepoWriteFailed => .ostree_repo_write_failed,
        error.MtreeInsertFailed => .ostree_mtree_insert_failed,

        else => .unexpected,
    };
}
