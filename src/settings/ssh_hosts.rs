//! Shared SSH address book. These records do not register execution nodes or hold credentials.
use serde::{Deserialize, Serialize};
use std::{
    io::Write,
    path::{Path, PathBuf},
};
use tokio::sync::Mutex;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Host {
    pub id: String,
    pub revision: u64,
    #[serde(flatten)]
    pub address: Address,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Address {
    pub name: String,
    pub host: String,
    pub user: String,
    pub port: u16,
    #[serde(default)]
    pub note: String,
}

impl Address {
    fn validated(mut self) -> Result<Self, Error> {
        self.name = self.name.trim().to_owned();
        self.host = self.host.trim().to_ascii_lowercase();
        self.user = self.user.trim().to_owned();
        self.note = self.note.trim().to_owned();
        if self.name.is_empty()
            || self.name.len() > 200
            || self.note.len() > 2000
            || self.port == 0
            || self.host.is_empty()
            || self.host.len() > 253
            || self.user.is_empty()
            || self.user.len() > 128
            || self.host.starts_with('-')
            || self.user.starts_with('-')
            || !self
                .host
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || ".-:[]_".contains(c))
            || !self
                .user
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
            || self.name.chars().any(char::is_control)
            || self.note.contains('\0')
        {
            return Err(Error::Invalid);
        }
        Ok(self)
    }
    fn same_target(&self, other: &Self) -> bool {
        self.host == other.host && self.user == other.user && self.port == other.port
    }
}

#[derive(Debug)]
pub enum Error {
    Invalid,
    Conflict,
    NotFound,
    Io(std::io::Error),
}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}

#[derive(Debug)]
pub struct Store {
    path: PathBuf,
    lock: Mutex<()>,
}
impl Store {
    pub fn new(root: &Path) -> Self {
        Self {
            path: root.join(".sandboxed-sh/ssh-hosts.json"),
            lock: Mutex::new(()),
        }
    }
    fn read(&self) -> Result<Vec<Host>, Error> {
        match std::fs::read(&self.path) {
            Ok(data) => serde_json::from_slice(&data)
                .map_err(|e| Error::Io(std::io::Error::new(std::io::ErrorKind::InvalidData, e))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(vec![]),
            Err(e) => Err(e.into()),
        }
    }
    fn persist(&self, hosts: &[Host]) -> Result<(), Error> {
        let dir = self.path.parent().expect("address book parent");
        std::fs::create_dir_all(dir)?;
        let mut file = tempfile::NamedTempFile::new_in(dir)?;
        file.write_all(&serde_json::to_vec_pretty(hosts).map_err(std::io::Error::other)?)?;
        file.as_file().sync_all()?;
        file.persist(&self.path).map_err(|e| Error::Io(e.error))?;
        Ok(())
    }
    pub async fn list(&self) -> Result<Vec<Host>, Error> {
        let _guard = self.lock.lock().await;
        self.read()
    }
    pub async fn create(&self, address: Address) -> Result<Host, Error> {
        let address = address.validated()?;
        let _guard = self.lock.lock().await;
        let mut hosts = self.read()?;
        // Idempotent import/retry: never overwrite the server's existing label/note.
        if let Some(existing) = hosts.iter().find(|h| h.address.same_target(&address)) {
            return Ok(existing.clone());
        }
        if hosts.len() >= 1000 {
            return Err(Error::Invalid);
        }
        let host = Host {
            id: uuid::Uuid::new_v4().to_string(),
            revision: 1,
            address,
        };
        hosts.push(host.clone());
        self.persist(&hosts)?;
        Ok(host)
    }
    pub async fn update(&self, id: &str, revision: u64, address: Address) -> Result<Host, Error> {
        let address = address.validated()?;
        let _guard = self.lock.lock().await;
        let mut hosts = self.read()?;
        let index = hosts
            .iter()
            .position(|h| h.id == id)
            .ok_or(Error::NotFound)?;
        if hosts[index].revision != revision
            || hosts
                .iter()
                .any(|h| h.id != id && h.address.same_target(&address))
        {
            return Err(Error::Conflict);
        }
        let host = Host {
            id: id.to_owned(),
            revision: revision.checked_add(1).ok_or(Error::Conflict)?,
            address,
        };
        hosts[index] = host.clone();
        self.persist(&hosts)?;
        Ok(host)
    }
    pub async fn remove(&self, id: &str, revision: u64) -> Result<(), Error> {
        let _guard = self.lock.lock().await;
        let mut hosts = self.read()?;
        let index = hosts
            .iter()
            .position(|h| h.id == id)
            .ok_or(Error::NotFound)?;
        if hosts[index].revision != revision {
            return Err(Error::Conflict);
        }
        hosts.remove(index);
        self.persist(&hosts)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn address() -> Address {
        Address {
            name: "Spark".into(),
            host: "SPARK.local".into(),
            user: "thomas".into(),
            port: 22,
            note: "GPU".into(),
        }
    }
    #[tokio::test]
    async fn ssh_hosts_persist_deduplicate_and_reject_stale_writes() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::new(root.path());
        let host = store.create(address()).await.unwrap();
        assert_eq!(store.create(address()).await.unwrap(), host);
        let mut edited = address();
        edited.note = "Updated".into();
        let next = store.update(&host.id, 1, edited.clone()).await.unwrap();
        assert_eq!(next.revision, 2);
        assert!(matches!(
            store.update(&host.id, 1, edited).await,
            Err(Error::Conflict)
        ));
        assert!(matches!(
            store.remove(&host.id, 1).await,
            Err(Error::Conflict)
        ));
        assert_eq!(Store::new(root.path()).list().await.unwrap(), vec![next]);
        store.remove(&host.id, 2).await.unwrap();
        assert!(store.list().await.unwrap().is_empty());
    }
    #[tokio::test]
    async fn ssh_hosts_invalid_or_corrupt_data_is_not_overwritten() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::new(root.path());
        let mut invalid = address();
        invalid.host = "host; command".into();
        assert!(matches!(store.create(invalid).await, Err(Error::Invalid)));
        store.create(address()).await.unwrap();
        std::fs::write(&store.path, b"broken").unwrap();
        assert!(matches!(store.create(address()).await, Err(Error::Io(_))));
        assert_eq!(std::fs::read(&store.path).unwrap(), b"broken");
    }
    #[tokio::test]
    async fn ssh_hosts_concurrent_updates_have_one_winner() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::new(root.path());
        let host = store.create(address()).await.unwrap();
        let (a, b) = tokio::join!(
            store.update(&host.id, 1, address()),
            store.update(&host.id, 1, address())
        );
        assert_ne!(a.is_ok(), b.is_ok());
    }
}
