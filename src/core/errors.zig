//! Stable process exit codes, part of the CLI's public contract.

pub const ExitCode = enum(u8) {
    success = 0,
    test_failure = 1,
    config_error = 2,
    internal_error = 3,
};
