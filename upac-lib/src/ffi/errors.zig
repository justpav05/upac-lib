pub const Operation = enum { install, uninstall, rollback, init, diff, list };

// A listing of all possible return codes used to signal success or specific runtime errors
pub const ErrorCode = enum(i32) {
    ok = 0,

    unexpected = 1,
    out_of_memory = 2,
    file_not_found = 3,
    permission_denied = 4,
    invalid_path = 5,
    no_space_left = 6,
    abi_mismatch = 7,

    tread_error = 9,
    lock_would_block = 10,

    db_missing_field = 20,
    db_missing_section = 21,
    db_invalid_entry = 22,
    db_parse_error = 23,
    db_write_database_failed = 24,

    // Installer errors
    install_already_installed = 30,
    install_package_path_not_found = 31,
    install_collet_file_checksum_failed = 32,
    install_checkout_failed = 33,
    install_cancelled = 34,
    install_max_retries_exceeded = 35,

    // Uninstall errors
    uninstall_not_found = 40,
    uninstall_failed = 41,

    ostree_repo_open_failed = 50,
    ostree_repo_transaction_failed = 51,
    ostree_commit = 52,
    ostree_diff = 53,
    ostree_rollback = 54,
    ostree_no_parent = 55,
    ostree_staging_failed = 56,
    ostree_swap_failed = 57,

    already_initialized = 60,
    create_dir_failed = 61,
    not_a_directory = 62,
    ostree_init_failed = 63,
    directory_not_empty = 64,
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
            else => null,
        },
        .install => switch (err) {
            error.AlreadyInstalled => .install_already_installed,
            error.PackagePathNotFound => .install_package_path_not_found,
            error.CollectFileChecksumsFailed => .install_collet_file_checksum_failed,
            error.CheckoutFailed => .install_checkout_failed,
            error.Cancelled => .install_cancelled,
            error.MaxRetriesExceeded => .install_max_retries_exceeded,
            else => null,
        },
        .uninstall => switch (err) {
            error.PackageNotFound => .uninstall_not_found,
            error.UninstallFailed => .uninstall_failed,
            error.MissingRepository => .ostree_repo_open_failed,
            else => null,
        },
        .rollback => switch (err) {
            error.RepoOpenFailed => .ostree_repo_open_failed,
            error.RepoTransactionFailed => .ostree_repo_transaction_failed,
            error.RollbackFailed => .ostree_rollback,
            error.NoPreviousCommit => .ostree_no_parent,
            else => null,
        },
        else => null,
    };

    if (specific) |code| return code;

    return switch (err) {
        error.OutOfMemory, error.AllocZFailed, error.MakeFailed => .out_of_memory,
        error.InvalidPath, error.BadPathName, error.RepoPathNotFound => .invalid_path,
        error.FileNotFound => .file_not_found,
        error.AccessDenied => .permission_denied,
        error.AbiMismatch => .abi_mismatch,
        error.WouldBlock => .lock_would_block,
        error.ErrorTreadError => .tread_error,
        error.NotEnoughSpace => .no_space_left,
        error.MissingField => .db_missing_field,
        error.MissingSection => .db_missing_section,
        error.InvalidEntry => .db_invalid_entry,
        error.ParseError => .db_parse_error,
        error.WriteDatabaseFailed => .db_write_database_failed,
        else => .unexpected,
    };
}
