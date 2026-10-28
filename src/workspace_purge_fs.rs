//! Linux descriptor-relative reclamation. A pathname identity check is never
//! authority to recursively remove whatever later occupies that pathname.
use std::ffi::CString;
use std::fs::File;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

fn identity(file: &File) -> Result<String, String> {
    let meta = file.metadata().map_err(|e| e.to_string())?;
    if !meta.is_dir() {
        return Err("Not a physical directory".into());
    }
    Ok(format!("{}:{}", meta.dev(), meta.ino()))
}
fn component(path: &Path) -> Result<CString, String> {
    use std::os::unix::ffi::OsStrExt;
    let name = path.file_name().ok_or("Missing directory name")?;
    CString::new(name.as_bytes()).map_err(|e| e.to_string())
}
fn open_parent(path: &Path, expected: &str) -> Result<File, String> {
    let parent = File::options()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(path.parent().ok_or("Missing parent")?)
        .map_err(|e| e.to_string())?;
    if identity(&parent)? != expected {
        return Err("Parent identity changed".into());
    }
    Ok(parent)
}
#[cfg(test)]
thread_local! { static FAIL_PARENT_SYNC: std::cell::Cell<bool> = const { std::cell::Cell::new(false) }; }

#[cfg(test)]
pub(crate) fn fail_next_parent_sync() {
    FAIL_PARENT_SYNC.set(true);
}

fn sync_parent_file(parent: &File) -> Result<(), String> {
    #[cfg(test)]
    if FAIL_PARENT_SYNC.replace(false) {
        return Err("injected parent fsync failure".into());
    }
    parent.sync_all().map_err(|e| e.to_string())
}

pub(crate) fn sync_parent(path: &Path, expected: &str) -> Result<(), String> {
    sync_parent_file(&open_parent(path, expected)?)
}

/// Keep quarantine inaccessible through ordinary paths to other Unix users.
/// Same-uid/privileged writers must participate in lifecycle admission.
pub(crate) fn secure_directory(
    path: &Path,
    parent_identity: &str,
    expected: &str,
) -> Result<(), String> {
    let parent = open_parent(path, parent_identity)?;
    let meta = parent.metadata().map_err(|e| e.to_string())?;
    let uid = unsafe { libc::geteuid() };
    if meta.uid() != uid || meta.mode() & 0o022 != 0 {
        return Err("Workspace parent is writable by another principal".into());
    }
    let directory = open_child(&parent, &component(path)?).map_err(|e| e.to_string())?;
    if identity(&directory)? != expected
        || directory.metadata().map_err(|e| e.to_string())?.uid() != uid
    {
        return Err("Workspace directory ownership changed".into());
    }
    set_mode(&directory, 0o700)?;
    directory.sync_all().map_err(|e| e.to_string())
}

fn set_mode(directory: &File, mode: u32) -> Result<(), String> {
    if unsafe { libc::fchmod(directory.as_raw_fd(), mode as libc::mode_t) } != 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok(())
}

pub(crate) fn restore_mode(
    path: &Path,
    parent_identity: &str,
    expected: &str,
    mode: u32,
) -> Result<(), String> {
    let parent = open_parent(path, parent_identity)?;
    let directory = open_child(&parent, &component(path)?).map_err(|e| e.to_string())?;
    if identity(&directory)? != expected {
        return Err("Restored directory changed".into());
    }
    set_mode(&directory, mode & 0o7777)?;
    directory.sync_all().map_err(|e| e.to_string())
}

fn open_child(parent: &File, name: &CString) -> Result<File, std::io::Error> {
    #[repr(C)]
    struct OpenHow {
        flags: u64,
        mode: u64,
        resolve: u64,
    }
    let how = OpenHow {
        flags: (libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC) as u64,
        mode: 0,
        // RESOLVE_NO_XDEV | RESOLVE_NO_SYMLINKS | RESOLVE_BENEATH. Checking
        // dev alone cannot detect a same-device bind mount introduced mid-sweep.
        resolve: 0x01 | 0x04 | 0x08,
    };
    // SAFETY: the CString is terminated, OpenHow has the kernel ABI layout,
    // and a successful syscall returns a fresh owned descriptor. Unsupported
    // kernels fail closed; there is no pathname-based fallback.
    let fd = unsafe {
        libc::syscall(
            libc::SYS_openat2,
            parent.as_raw_fd(),
            name.as_ptr(),
            &how,
            std::mem::size_of::<OpenHow>(),
        ) as i32
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

pub(crate) fn rename(
    source: &Path,
    destination: &Path,
    parent_identity: &str,
    directory_identity: &str,
) -> Result<(), String> {
    if source.parent() != destination.parent() {
        return Err("Quarantine must share its source parent".into());
    }
    let parent = open_parent(source, parent_identity)?;
    let from = component(source)?;
    let to = component(destination)?;
    let directory = open_child(&parent, &from).map_err(|e| e.to_string())?;
    if identity(&directory)? != directory_identity {
        return Err("Directory identity changed".into());
    }
    // Never overwrite a newly recreated source or a preexisting quarantine.
    let result = unsafe {
        libc::renameat2(
            parent.as_raw_fd(),
            from.as_ptr(),
            parent.as_raw_fd(),
            to.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if result != 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    sync_parent_file(&parent)?;
    let moved = open_child(&parent, &to).map_err(|e| e.to_string())?;
    if identity(&moved)? != directory_identity {
        return Err("Directory was replaced during rename; retained for reconciliation".into());
    }
    Ok(())
}

fn clear_directory(directory: &File, device: u64) -> Result<(), String> {
    // /proc/self/fd resolves the held inode, even if its original pathname is
    // renamed/replaced. Child opens/unlinks remain relative to that descriptor.
    let entries = std::fs::read_dir(format!("/proc/self/fd/{}", directory.as_raw_fd()))
        .map_err(|e| e.to_string())?;
    for entry in entries {
        use std::os::unix::ffi::OsStrExt;
        let entry = entry.map_err(|e| e.to_string())?;
        let name = CString::new(entry.file_name().as_bytes()).map_err(|e| e.to_string())?;
        match open_child(directory, &name) {
            Ok(child) => {
                if child.metadata().map_err(|e| e.to_string())?.dev() != device {
                    return Err("Nested mount requires reconciliation".into());
                }
                clear_directory(&child, device)?;
                // The inode may have moved while clearing it. A replacement
                // directory never gets recursively traversed or cleared.
                let current = open_child(directory, &name).map_err(|e| e.to_string())?;
                if identity(&current)? != identity(&child)? {
                    return Err("Child directory replaced".into());
                }
                if unsafe {
                    libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR)
                } != 0
                {
                    return Err(std::io::Error::last_os_error().to_string());
                }
            }
            Err(error)
                if matches!(
                    error.raw_os_error(),
                    Some(libc::ENOTDIR) | Some(libc::ELOOP)
                ) =>
            {
                // unlinkat does not follow symlinks. If replaced with a directory
                // it fails instead of entering the replacement.
                if unsafe { libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), 0) } != 0 {
                    return Err(std::io::Error::last_os_error().to_string());
                }
            }
            Err(error) => return Err(error.to_string()),
        }
    }
    directory.sync_all().map_err(|e| e.to_string())
}

pub(crate) fn remove(
    path: &Path,
    parent_identity: &str,
    directory_identity: &str,
) -> Result<(), String> {
    let parent = open_parent(path, parent_identity)?;
    let name = component(path)?;
    let directory = match open_child(&parent, &name) {
        Ok(directory) => directory,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return sync_parent_file(&parent);
        }
        Err(error) => return Err(error.to_string()),
    };
    if identity(&directory)? != directory_identity {
        return Err("Quarantine identity changed".into());
    }
    let meta = directory.metadata().map_err(|e| e.to_string())?;
    if meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o7777 != 0o700 {
        return Err("Quarantine must be private before removal".into());
    }
    let parent_meta = parent.metadata().map_err(|e| e.to_string())?;
    if parent_meta.uid() != unsafe { libc::geteuid() } || parent_meta.mode() & 0o022 != 0 {
        return Err("Quarantine parent is not exclusive".into());
    }
    clear_directory(
        &directory,
        directory.metadata().map_err(|e| e.to_string())?.dev(),
    )?;
    let current = open_child(&parent, &name).map_err(|e| e.to_string())?;
    if identity(&current)? != directory_identity {
        return Err("Quarantine replaced during removal".into());
    }
    if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) } != 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    sync_parent_file(&parent)
}

/// Multiple views of a device (bind mounts/subvolumes), and mounts nested in
/// the target, cannot establish physical disjointness from pathnames alone.
pub(crate) fn require_unambiguous_mount(path: &Path) -> Result<(), String> {
    check_mounts(path, true)
}

/// Execution-private scratch is never shared workspace source. systemd's
/// ReadWritePaths creates additional views of its backing filesystem; those
/// unrelated views do not invalidate its persisted retirement/inode receipt.
/// Nested mounts remain forbidden, also enforced at traversal by openat2.
pub(crate) fn require_no_nested_mounts(path: &Path) -> Result<(), String> {
    check_mounts(path, false)
}

fn check_mounts(path: &Path, unique_view: bool) -> Result<(), String> {
    let meta = std::fs::metadata(path).map_err(|e| e.to_string())?;
    let device = format!("{}:{}", libc::major(meta.dev()), libc::minor(meta.dev()));
    let mounts = std::fs::read_to_string("/proc/self/mountinfo").map_err(|e| e.to_string())?;
    check_mount_inventory(path, &device, &mounts, unique_view)
}

fn check_mount_inventory(
    path: &Path,
    device: &str,
    mounts: &str,
    unique_view: bool,
) -> Result<(), String> {
    let mut views = 0;
    for line in mounts.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() < 10 || !fields.contains(&"-") {
            return Err("Malformed mount inventory".into());
        }
        if fields[2] == device {
            views += 1;
        }
        // Escaped paths cannot prove disjointness; the mount grammar uses
        // octal escapes for whitespace/backslashes in names.
        if fields[4].contains('\\') {
            return Err("Ambiguous mount path".into());
        }
        let mount = Path::new(fields[4]);
        if mount.starts_with(path) {
            return Err("Workspace includes a mount point".into());
        }
    }
    if views == 0 || (unique_view && views != 1) {
        return Err("Multiple or unavailable filesystem views; retain shared workspace".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn private_scratch_allows_systemd_bind_views_but_never_nested_mounts() {
        let scratch = Path::new("/var/lib/sandboxed-node/.scratch");
        let mounts = "1 0 8:1 / / ro - ext4 /dev/root ro\n2 1 8:1 /var/lib/sandboxed-node /var/lib/sandboxed-node rw - ext4 /dev/root rw\n";
        assert!(check_mount_inventory(scratch, "8:1", mounts, false).is_ok());
        assert!(check_mount_inventory(scratch, "8:1", mounts, true).is_err());
        for device in ["8:1", "0:9"] {
            let nested = format!("{mounts}3 2 {device} / /var/lib/sandboxed-node/.scratch/id/nested rw - tmpfs tmpfs rw\n");
            assert!(check_mount_inventory(scratch, "8:1", &nested, false).is_err());
        }
        assert!(check_mount_inventory(scratch, "8:1", "malformed", false).is_err());
        assert!(check_mount_inventory(scratch, "8:2", mounts, false).is_err());
    }

    #[test]
    fn workspace_purge_anchored_clear_does_not_traverse_replacement_directory() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("quarantine");
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("authorized"), b"discarded").unwrap();
        let parent = File::open(temp.path()).unwrap();
        let name = component(&path).unwrap();
        let held = open_child(&parent, &name).unwrap();
        std::fs::rename(&path, temp.path().join("moved-authorized")).unwrap();
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("replacement-work"), b"preserve").unwrap();
        clear_directory(&held, held.metadata().unwrap().dev()).unwrap();
        assert_eq!(
            std::fs::read(path.join("replacement-work")).unwrap(),
            b"preserve"
        );
        assert!(remove(
            &path,
            &identity(&parent).unwrap(),
            &identity(&held).unwrap()
        )
        .is_err());
    }
    #[test]
    fn workspace_purge_anchored_removal_does_not_follow_child_symlinks() {
        let temp = tempfile::tempdir().unwrap();
        let external = temp.path().join("external");
        let trash = temp.path().join("trash");
        std::fs::create_dir(&external).unwrap();
        std::fs::create_dir(&trash).unwrap();
        std::fs::write(external.join("work"), b"preserve").unwrap();
        std::os::unix::fs::symlink(&external, trash.join("link")).unwrap();
        let parent = File::open(temp.path()).unwrap();
        let held = File::open(&trash).unwrap();
        secure_directory(
            &trash,
            &identity(&parent).unwrap(),
            &identity(&held).unwrap(),
        )
        .unwrap();
        remove(
            &trash,
            &identity(&parent).unwrap(),
            &identity(&held).unwrap(),
        )
        .unwrap();
        assert!(external.join("work").exists());
        assert!(!trash.exists());
    }
}
