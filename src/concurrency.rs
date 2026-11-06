//! Shared concurrency primitives: monotonic atomic timestamps, per-key async
//! mutexes, wait-free `ArcSwap` snapshot stores, lock-free atomic sample rings,
//! and coalesced off-thread persistence.

use std::hash::Hash;
use std::ops::{Deref, DerefMut};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock, Weak};
use std::time::{Duration, Instant};

use arc_swap::{ArcSwap, Guard};
use dashmap::DashMap;
use tokio::sync::{Mutex as AsyncMutex, MutexGuard as AsyncMutexGuard, Notify, OwnedMutexGuard};

static MONOTONIC_EPOCH: OnceLock<Instant> = OnceLock::new();

fn epoch() -> Instant {
    *MONOTONIC_EPOCH.get_or_init(Instant::now)
}

/// Non-zero monotonic nanoseconds since process start (`0` is reserved as `None`).
#[inline]
pub fn monotonic_nanos() -> u64 {
    let elapsed = epoch().elapsed().as_nanos();
    let clamped = elapsed.min((u64::MAX - 1) as u128) as u64;
    clamped + 1
}

/// Elapsed duration since a previously recorded [`monotonic_nanos`] value.
/// Returns `None` when `recorded == 0`.
#[inline]
pub fn elapsed_since_monotonic(recorded: u64) -> Option<Duration> {
    if recorded == 0 {
        return None;
    }
    let now = monotonic_nanos();
    Some(Duration::from_nanos(now.saturating_sub(recorded)))
}

/// Duration between two non-zero [`monotonic_nanos`] marks (`later - earlier`).
#[inline]
pub fn duration_between_monotonic(earlier: u64, later: u64) -> Option<Duration> {
    if earlier == 0 || later == 0 {
        return None;
    }
    Some(Duration::from_nanos(later.saturating_sub(earlier)))
}

/// Wait-free snapshot container backed by [`ArcSwap`] with serialized copy-on-write
/// updates and drop-in `.read().await` / `.write().await` compatibility.
pub struct ArcSwapStore<T> {
    inner: ArcSwap<T>,
    writer: AsyncMutex<()>,
}

impl<T: Default> Default for ArcSwapStore<T> {
    fn default() -> Self {
        Self::new(T::default())
    }
}

impl<T> ArcSwapStore<T> {
    pub fn new(initial: T) -> Self {
        Self {
            inner: ArcSwap::from_pointee(initial),
            writer: AsyncMutex::new(()),
        }
    }

    /// Synchronous wait-free borrow of the current snapshot (zero atomic refcount ops).
    #[inline]
    pub fn load(&self) -> Guard<Arc<T>> {
        self.inner.load()
    }

    /// Synchronous wait-free `Arc<T>` clone of the current snapshot.
    #[inline]
    pub fn load_full(&self) -> Arc<T> {
        self.inner.load_full()
    }

    /// Atomically replace the snapshot directly.
    #[inline]
    pub fn store(&self, next: Arc<T>) {
        self.inner.store(next);
    }

    /// Drop-in async compatibility for `RwLock::read().await` that performs zero locking
    /// and returns a `Send + Sync` owned snapshot guard safe across `.await` points.
    #[inline]
    pub async fn read(&self) -> ArcSwapReadGuard<T> {
        ArcSwapReadGuard(self.inner.load_full())
    }

    /// Acquire serialized writer access, cloning the current snapshot for mutation
    /// and atomically publishing the updated value on drop.
    pub async fn write(&self) -> ArcSwapWriteGuard<'_, T>
    where
        T: Clone,
    {
        let guard = self.writer.lock().await;
        let working = (*self.inner.load_full()).clone();
        ArcSwapWriteGuard {
            store: self,
            _writer_guard: guard,
            working: Some(working),
        }
    }

    /// Acquire the writer mutex directly when callers build and persist a new
    /// snapshot manually before calling [`Self::store`].
    pub async fn lock_writer(&self) -> AsyncMutexGuard<'_, ()> {
        self.writer.lock().await
    }
}

pub struct ArcSwapReadGuard<T>(Arc<T>);

impl<T> Deref for ArcSwapReadGuard<T> {
    type Target = T;

    #[inline]
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

pub struct ArcSwapWriteGuard<'a, T> {
    store: &'a ArcSwapStore<T>,
    _writer_guard: AsyncMutexGuard<'a, ()>,
    working: Option<T>,
}

impl<T> Deref for ArcSwapWriteGuard<'_, T> {
    type Target = T;

    #[inline]
    fn deref(&self) -> &Self::Target {
        self.working.as_ref().expect("working snapshot alive")
    }
}

impl<T> DerefMut for ArcSwapWriteGuard<'_, T> {
    #[inline]
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.working.as_mut().expect("working snapshot alive")
    }
}

impl<T> Drop for ArcSwapWriteGuard<'_, T> {
    fn drop(&mut self) {
        if let Some(updated) = self.working.take() {
            self.store.inner.store(Arc::new(updated));
        }
    }
}

/// Sharded per-key async mutex registry that self-prunes unused keys via `Weak`.
///
/// Acquiring a key never blocks operations on unrelated keys and leaves zero
/// permanent map growth once guards drop.
pub struct KeyedAsyncLocks<K: Eq + Hash + Clone> {
    locks: DashMap<K, Weak<AsyncMutex<()>>>,
}

impl<K: Eq + Hash + Clone> Default for KeyedAsyncLocks<K> {
    fn default() -> Self {
        Self::new()
    }
}

impl<K: Eq + Hash + Clone> KeyedAsyncLocks<K> {
    pub fn new() -> Self {
        Self {
            locks: DashMap::new(),
        }
    }

    /// Look up or insert the per-key async mutex without blocking unrelated shards,
    /// opportunistically pruning expired `Weak` entries when the table grows.
    pub fn get(&self, key: K) -> Arc<AsyncMutex<()>> {
        if self.locks.len() > 256 {
            self.locks.retain(|_, weak| weak.strong_count() > 0);
        }
        if let Some(existing) = self.locks.get(&key).and_then(|entry| entry.upgrade()) {
            return existing;
        }
        let mut entry = self.locks.entry(key).or_default();
        if let Some(existing) = entry.value().upgrade() {
            existing
        } else {
            let fresh = Arc::new(AsyncMutex::new(()));
            *entry.value_mut() = Arc::downgrade(&fresh);
            fresh
        }
    }

    pub async fn lock(&self, key: K) -> KeyedAsyncGuard<'_, K>
    where
        K: Send + Sync + 'static,
    {
        let arc_mutex = self.get(key.clone());
        let guard = arc_mutex.lock_owned().await;
        KeyedAsyncGuard {
            key: Some(key),
            map: &self.locks,
            _guard: guard,
        }
    }
}

pub struct KeyedAsyncGuard<'a, K: Eq + Hash + Clone> {
    key: Option<K>,
    map: &'a DashMap<K, Weak<AsyncMutex<()>>>,
    _guard: OwnedMutexGuard<()>,
}

impl<K: Eq + Hash + Clone> Drop for KeyedAsyncGuard<'_, K> {
    fn drop(&mut self) {
        if let Some(key) = self.key.take() {
            let _ = self.map.remove_if(&key, |_, weak| weak.strong_count() <= 1);
        }
    }
}

/// Fixed-capacity lock-free ring buffer of `u64` samples (`u64::MAX` = empty slot).
///
/// Recording is a single `fetch_add` + `store` with zero mutexes. `values()`
/// copies populated slots out into an owned `Vec<u64>` so callers can sort and
/// compute percentiles completely outside any lock.
pub struct AtomicRingSamples<const N: usize> {
    slots: Box<[AtomicU64; N]>,
    cursor: AtomicU64,
}

impl<const N: usize> Default for AtomicRingSamples<N> {
    fn default() -> Self {
        Self::new()
    }
}

impl<const N: usize> AtomicRingSamples<N> {
    const EMPTY: u64 = u64::MAX;

    pub fn new() -> Self {
        let vec: Vec<AtomicU64> = (0..N).map(|_| AtomicU64::new(Self::EMPTY)).collect();
        let slots: Box<[AtomicU64; N]> = vec
            .into_boxed_slice()
            .try_into()
            .unwrap_or_else(|_| unreachable!("exact length N"));
        Self {
            slots,
            cursor: AtomicU64::new(0),
        }
    }

    #[inline]
    pub fn record(&self, sample: u64) {
        let value = sample.min(Self::EMPTY - 1);
        let idx = (self.cursor.fetch_add(1, Ordering::Relaxed) as usize) % N;
        self.slots[idx].store(value, Ordering::Relaxed);
    }

    pub fn values(&self) -> Vec<u64> {
        let written = (self.cursor.load(Ordering::Relaxed) as usize).min(N);
        let mut out = Vec::with_capacity(written);
        for slot in self.slots.iter() {
            let v = slot.load(Ordering::Relaxed);
            if v != Self::EMPTY {
                out.push(v);
            }
        }
        out
    }
}

/// Coalesces rapid state mutations into asynchronous atomic file writes
/// (`tmp` + `rename` via `tokio::fs`) without blocking callers or holding locks.
pub struct CoalescedAsyncWriter {
    requested_seq: AtomicU64,
    flushed_seq: AtomicU64,
    running: AtomicBool,
    notify: Arc<Notify>,
    persist_lock: AsyncMutex<()>,
    min_interval: Duration,
    flush: Box<dyn Fn() -> FlushFuture + Send + Sync>,
    weak: Weak<Self>,
}

type FlushFuture = std::pin::Pin<Box<dyn std::future::Future<Output = std::io::Result<()>> + Send>>;

struct WriterRunningGuard(Weak<CoalescedAsyncWriter>);

impl Drop for WriterRunningGuard {
    fn drop(&mut self) {
        if let Some(writer) = self.0.upgrade() {
            writer.running.store(false, Ordering::Release);
        }
    }
}

impl CoalescedAsyncWriter {
    pub fn spawn<F>(path: PathBuf, min_interval: Duration, build_bytes: F) -> Arc<Self>
    where
        F: Fn() -> Option<Vec<u8>> + Send + Sync + 'static,
    {
        Self::spawn_with_flush(min_interval, move || {
            let bytes = build_bytes();
            let path = path.clone();
            async move {
                let bytes = bytes.ok_or_else(|| std::io::Error::other("snapshot unavailable"))?;
                write_atomic_async(&path, &bytes, None).await
            }
        })
    }

    pub fn spawn_with_flush<F, Fut>(min_interval: Duration, flush: F) -> Arc<Self>
    where
        F: Fn() -> Fut + Send + Sync + 'static,
        Fut: std::future::Future<Output = std::io::Result<()>> + Send + 'static,
    {
        Arc::new_cyclic(|weak| Self {
            requested_seq: AtomicU64::new(0),
            flushed_seq: AtomicU64::new(0),
            running: AtomicBool::new(false),
            notify: Arc::new(Notify::new()),
            persist_lock: AsyncMutex::new(()),
            min_interval,
            flush: Box::new(move || Box::pin(flush())),
            weak: weak.clone(),
        })
    }

    pub fn trigger(&self) {
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            return;
        };
        self.notify.notify_one();
        self.spawn_worker(&handle);
    }

    fn spawn_worker(&self, handle: &tokio::runtime::Handle) {
        if self
            .running
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return;
        }
        let weak = self.weak.clone();
        let notify = Arc::clone(&self.notify);
        let interval = self.min_interval;
        let guard = WriterRunningGuard(weak.clone());
        handle.spawn(async move {
            let _guard = guard;
            let mut backoff = Duration::from_millis(25);
            loop {
                let notified = notify.notified();
                tokio::pin!(notified);
                notified.as_mut().enable();
                let Some(writer) = weak.upgrade() else {
                    return;
                };
                let already_flushed = writer.flushed_seq.load(Ordering::Acquire)
                    >= writer.requested_seq.load(Ordering::Acquire);
                drop(writer);
                if already_flushed {
                    notified.await;
                    if !interval.is_zero() {
                        tokio::time::sleep(interval).await;
                    }
                    continue;
                }
                loop {
                    let Some(writer) = weak.upgrade() else {
                        return;
                    };
                    let result = writer.flush_now().await;
                    drop(writer);
                    match result {
                        Ok(()) => {
                            backoff = Duration::from_millis(25);
                            break;
                        }
                        Err(error) => {
                            tracing::warn!(%error, "coalesced async persistence failed");
                            tokio::time::sleep(backoff).await;
                            backoff = (backoff * 2).min(Duration::from_secs(1));
                        }
                    }
                }
            }
        });
    }

    #[inline]
    pub fn mark_dirty(&self) {
        let _ = self.requested_seq.fetch_add(1, Ordering::AcqRel) + 1;
        self.trigger();
    }

    pub async fn flush_now(&self) -> std::io::Result<()> {
        let _guard = self.persist_lock.lock().await;
        loop {
            let target_seq = self.requested_seq.load(Ordering::Acquire);
            if self.flushed_seq.load(Ordering::Acquire) >= target_seq {
                return Ok(());
            }
            (self.flush)().await?;
            self.flushed_seq.store(target_seq, Ordering::Release);
        }
    }
}

/// Write `bytes` to a sibling temporary file and atomically rename over `path`
/// using `tokio::fs`, optionally enforcing Unix file mode (e.g. `0o600`).
pub async fn write_atomic_async(
    path: &std::path::Path,
    bytes: &[u8],
    unix_mode: Option<u32>,
) -> std::io::Result<()> {
    let path = path.to_path_buf();
    let bytes = bytes.to_vec();
    tokio::task::spawn_blocking(move || write_atomic(&path, &bytes, unix_mode))
        .await
        .map_err(std::io::Error::other)?
}

pub(crate) fn write_atomic(
    path: &std::path::Path,
    bytes: &[u8],
    unix_mode: Option<u32>,
) -> std::io::Result<()> {
    use std::io::Write;

    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| std::path::Path::new("."));
    std::fs::create_dir_all(parent)?;
    let unique = uuid::Uuid::new_v4().simple();
    let file_name = path.file_name().and_then(|n| n.to_str()).unwrap_or("state");
    let tmp_path = path.with_file_name(format!(".{file_name}.{unique}.tmp"));
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        if let Some(mode) = unix_mode {
            opts.mode(mode);
        }
    }
    #[cfg(not(unix))]
    let _ = unix_mode;
    let mut file = opts.open(&tmp_path)?;
    let result = (|| {
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&tmp_path, path)?;
        #[cfg(unix)]
        std::fs::File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp_path);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn wait_until_flushed(writer: &CoalescedAsyncWriter, seq: u64) {
        tokio::time::timeout(Duration::from_secs(5), async {
            while writer.flushed_seq.load(Ordering::Acquire) < seq {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }

    #[test]
    fn coalesced_failure_preserves_pending_sequence() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state");
        let attempts = Arc::new(AtomicU64::new(0));
        let writer = CoalescedAsyncWriter::spawn_with_flush(Duration::ZERO, {
            let attempts = attempts.clone();
            let path = path.clone();
            move || {
                let attempt = attempts.fetch_add(1, Ordering::AcqRel);
                let path = path.clone();
                async move {
                    if attempt == 0 {
                        Err(std::io::Error::other("transient failure"))
                    } else {
                        write_atomic_async(&path, b"state", None).await
                    }
                }
            }
        });
        writer.mark_dirty();
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            assert_eq!(
                writer.flush_now().await.unwrap_err().kind(),
                std::io::ErrorKind::Other
            );
            assert_eq!(writer.requested_seq.load(Ordering::Acquire), 1);
            assert_eq!(writer.flushed_seq.load(Ordering::Acquire), 0);
            writer.trigger();
            wait_until_flushed(&writer, 1).await;
        });
        assert_eq!(attempts.load(Ordering::Acquire), 2);
        assert_eq!(std::fs::read(path).unwrap(), b"state");
    }

    #[tokio::test]
    async fn coalesced_mutation_mid_flush_converges() {
        let entered = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        let attempts = Arc::new(AtomicU64::new(0));
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state");
        let writer = CoalescedAsyncWriter::spawn_with_flush(Duration::ZERO, {
            let entered = entered.clone();
            let release = release.clone();
            let attempts = attempts.clone();
            let path = path.clone();
            move || {
                let attempt = attempts.fetch_add(1, Ordering::AcqRel) + 1;
                let entered = entered.clone();
                let release = release.clone();
                let path = path.clone();
                async move {
                    if attempt == 1 {
                        entered.notify_one();
                        release.notified().await;
                    }
                    write_atomic_async(&path, attempt.to_string().as_bytes(), None).await
                }
            }
        });
        writer.mark_dirty();
        tokio::time::timeout(Duration::from_secs(5), entered.notified())
            .await
            .unwrap();
        writer.mark_dirty();
        assert_eq!(writer.flushed_seq.load(Ordering::Acquire), 0);
        release.notify_one();
        wait_until_flushed(&writer, 2).await;
        assert_eq!(writer.requested_seq.load(Ordering::Acquire), 2);
        assert_eq!(attempts.load(Ordering::Acquire), 2);
        assert_eq!(std::fs::read(path).unwrap(), b"2");
    }

    #[test]
    fn coalesced_mark_outside_runtime_remains_pending() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state");
        let writer =
            CoalescedAsyncWriter::spawn(path.clone(), Duration::ZERO, || Some(b"state".to_vec()));
        writer.mark_dirty();
        assert_eq!(writer.requested_seq.load(Ordering::Acquire), 1);
        assert_eq!(writer.flushed_seq.load(Ordering::Acquire), 0);
        assert!(!writer.running.load(Ordering::Acquire));
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(writer.flush_now())
            .unwrap();
        assert_eq!(writer.flushed_seq.load(Ordering::Acquire), 1);
        assert_eq!(std::fs::read(&path).unwrap(), b"state");
        writer.mark_dirty();
        assert_eq!(writer.requested_seq.load(Ordering::Acquire), 2);
        assert_eq!(writer.flushed_seq.load(Ordering::Acquire), 1);
        assert!(!writer.running.load(Ordering::Acquire));
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            writer.trigger();
            wait_until_flushed(&writer, 2).await;
        });
    }

    #[tokio::test]
    async fn coalesced_background_retries_without_mutation() {
        let attempts = Arc::new(AtomicU64::new(0));
        let writer = CoalescedAsyncWriter::spawn_with_flush(Duration::ZERO, {
            let attempts = attempts.clone();
            move || {
                let attempt = attempts.fetch_add(1, Ordering::AcqRel);
                async move {
                    if attempt == 0 {
                        Err(std::io::Error::other("transient"))
                    } else {
                        Ok(())
                    }
                }
            }
        });
        writer.mark_dirty();
        wait_until_flushed(&writer, 1).await;
        assert_eq!(attempts.load(Ordering::Acquire), 2);
        assert_eq!(writer.requested_seq.load(Ordering::Acquire), 1);
    }

    #[test]
    fn coalesced_newly_spawned_worker_flushes_preexisting_dirty_sequence_immediately() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state");
        let writer = CoalescedAsyncWriter::spawn(path.clone(), Duration::from_secs(3600), || {
            Some(b"preexisting-dirty".to_vec())
        });
        writer.mark_dirty();
        assert_eq!(writer.requested_seq.load(Ordering::Acquire), 1);
        assert_eq!(writer.flushed_seq.load(Ordering::Acquire), 0);
        assert!(!writer.running.load(Ordering::Acquire));

        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            writer.spawn_worker(&tokio::runtime::Handle::current());
            wait_until_flushed(&writer, 1).await;
        });
        assert_eq!(std::fs::read(&path).unwrap(), b"preexisting-dirty");

        drop(runtime);
        assert!(!writer.running.load(Ordering::Acquire));

        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let release = Arc::new(Notify::new());
        let aborted_writer = CoalescedAsyncWriter::spawn_with_flush(Duration::from_secs(3600), {
            let release = Arc::clone(&release);
            let entered_tx = std::sync::Mutex::new(Some(entered_tx));
            let path = path.clone();
            move || {
                let release = Arc::clone(&release);
                let tx = entered_tx.lock().unwrap().take();
                let path = path.clone();
                async move {
                    if let Some(tx) = tx {
                        let _ = tx.send(());
                        release.notified().await;
                    }
                    write_atomic_async(&path, b"after-abort", None).await
                }
            }
        });
        let runtime2 = tokio::runtime::Runtime::new().unwrap();
        runtime2.block_on(async {
            aborted_writer.mark_dirty();
            entered_rx.recv().unwrap();
        });
        drop(runtime2);
        assert!(!aborted_writer.running.load(Ordering::Acquire));
        assert_eq!(aborted_writer.requested_seq.load(Ordering::Acquire), 1);
        assert_eq!(aborted_writer.flushed_seq.load(Ordering::Acquire), 0);

        let runtime3 = tokio::runtime::Runtime::new().unwrap();
        runtime3.block_on(async {
            aborted_writer.trigger();
            wait_until_flushed(&aborted_writer, 1).await;
        });
        assert_eq!(std::fs::read(&path).unwrap(), b"after-abort");
    }

    #[test]
    fn monotonic_clock_never_returns_zero_and_advances() {
        let t1 = monotonic_nanos();
        assert!(t1 > 0);
        let t2 = monotonic_nanos();
        assert!(t2 >= t1);
        assert!(elapsed_since_monotonic(0).is_none());
        assert!(elapsed_since_monotonic(t1).is_some());
    }

    #[test]
    fn atomic_ring_wraps_without_locks() {
        let ring = AtomicRingSamples::<4>::new();
        assert!(ring.values().is_empty());
        for i in 1..=6 {
            ring.record(i * 10);
        }
        let mut vals = ring.values();
        vals.sort_unstable();
        assert_eq!(vals, vec![30, 40, 50, 60]);
    }

    #[tokio::test]
    async fn arc_swap_store_publishes_cow_updates() {
        let store = ArcSwapStore::new(vec![1, 2]);
        assert_eq!(&**store.load(), &[1, 2]);
        {
            let mut w = store.write().await;
            w.push(3);
        }
        assert_eq!(&*store.read().await, &[1, 2, 3]);
    }
}
