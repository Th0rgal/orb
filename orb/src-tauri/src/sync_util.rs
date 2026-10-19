//! Poison-tolerant locking. A panicking reader thread must never wedge the
//! registry, the exit watcher or the output stream: the data behind these
//! mutexes stays consistent at every await-free statement boundary.

use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

/// Lock, recovering the guard when another thread panicked while holding it.
pub(crate) fn lock<T: ?Sized>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// `Condvar::wait_while`, tolerant of poisoning.
pub(crate) fn wait_while<'a, T, F: FnMut(&mut T) -> bool>(
    condvar: &Condvar,
    guard: MutexGuard<'a, T>,
    condition: F,
) -> MutexGuard<'a, T> {
    condvar
        .wait_while(guard, condition)
        .unwrap_or_else(PoisonError::into_inner)
}

/// `Condvar::wait_timeout_while`, tolerant of poisoning.
pub(crate) fn wait_timeout_while<'a, T, F: FnMut(&mut T) -> bool>(
    condvar: &Condvar,
    guard: MutexGuard<'a, T>,
    timeout: Duration,
    condition: F,
) -> MutexGuard<'a, T> {
    condvar
        .wait_timeout_while(guard, timeout, condition)
        .unwrap_or_else(PoisonError::into_inner)
        .0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn a_poisoned_mutex_still_yields_its_value() {
        let shared = Arc::new(Mutex::new(7));
        let poisoner = Arc::clone(&shared);
        let _ = std::thread::spawn(move || {
            let _guard = poisoner.lock().unwrap();
            panic!("poison the lock");
        })
        .join();
        assert!(shared.is_poisoned());
        assert_eq!(*lock(&shared), 7);
    }
}
