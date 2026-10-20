use std::{
    io,
    os::fd::{FromRawFd, OwnedFd, RawFd},
};

pub(super) struct DescriptorDuplicator;
impl DescriptorDuplicator {
    pub(super) fn duplicate(fd: RawFd) -> io::Result<OwnedFd> {
        // SAFETY: fcntl validates the source descriptor. It creates an owned
        // duplicate and sets CLOEXEC in the same syscall, including under fork.
        let duplicate = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0) };
        if duplicate < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: fcntl returned a fresh, valid descriptor owned by this call.
        Ok(unsafe { OwnedFd::from_raw_fd(duplicate) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs::File, os::fd::AsRawFd};
    #[test]
    fn duplicate_is_owned_and_atomically_excluded_from_exec() {
        let source = File::open("/dev/null").unwrap();
        let original = source.as_raw_fd();
        let copied = DescriptorDuplicator::duplicate(original).unwrap();
        assert_ne!(copied.as_raw_fd(), original);
        // SAFETY: both descriptors are owned and live for these read-only queries.
        let flags = unsafe { libc::fcntl(copied.as_raw_fd(), libc::F_GETFD) };
        assert_ne!(flags & libc::FD_CLOEXEC, 0);
        drop(source);
        let copy: File = copied.into();
        assert!(copy.metadata().is_ok());
    }
    #[test]
    fn invalid_source_does_not_create_a_descriptor() {
        assert_eq!(
            DescriptorDuplicator::duplicate(-1)
                .unwrap_err()
                .raw_os_error(),
            Some(libc::EBADF)
        );
    }
}
