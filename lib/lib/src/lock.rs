// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::os::fd::{AsRawFd, OwnedFd};

use nix::errno::Errno;
use nix::sys::socket::{AddressFamily, SockFlag, SockType, UnixAddr, bind, socket};

use upac_abi::error::ErrorKind;

use crate::layout::runtime::LOCK_ADDRESS;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LockError {
    Busy,
    ReadOnly,
    Denied,
    PathMissing,
    Unexpected(Errno),
}

impl From<Errno> for LockError {
    fn from(errno: Errno) -> Self {
        match errno {
            Errno::EADDRINUSE => LockError::Busy,
            Errno::EROFS => LockError::ReadOnly,
            Errno::EPERM | Errno::EACCES => LockError::Denied,
            Errno::ENOENT => LockError::PathMissing,
            other => LockError::Unexpected(other),
        }
    }
}

impl From<LockError> for ErrorKind {
    fn from(error: LockError) -> Self {
        match error {
            LockError::Busy => ErrorKind::Unexpected,
            LockError::ReadOnly | LockError::Denied => ErrorKind::PermissionDenied,
            LockError::PathMissing => ErrorKind::InvalidPath,
            LockError::Unexpected(_) => ErrorKind::Unexpected,
        }
    }
}

pub struct Lock {
    _socket: OwnedFd,
}

impl Lock {
    pub fn acquire() -> Result<Lock, LockError> {
        let socket = socket(AddressFamily::Unix, SockType::Stream, SockFlag::SOCK_CLOEXEC, None)?;
        let address = UnixAddr::new_abstract(LOCK_ADDRESS.as_bytes())?;

        bind(socket.as_raw_fd(), &address)?;

        Ok(Lock { _socket: socket })
    }
}
