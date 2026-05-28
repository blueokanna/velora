use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

use anyhow::{anyhow, Result};
use once_cell::sync::OnceCell;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookshelfEntry {
    pub id: String,
    pub title: String,
    pub author: String,
    pub kind: String,
    pub path_or_url: String,
    pub book_meta_json: Option<String>,
    pub cover: Option<String>,
    pub last_chapter: u32,
    pub last_offset: u64,
    pub updated_at: i64,
    pub source_name: Option<String>,
    pub source_json: Option<String>,
    pub toc_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[flutter_rust_bridge::frb(ignore)]
pub struct BookshelfDb {
    pub entries: Vec<BookshelfEntry>,
}

struct StorageState {
    root: PathBuf,
    db: BookshelfDb,
}

static STATE: OnceCell<Mutex<StorageState>> = OnceCell::new();

fn db_path(root: &PathBuf) -> PathBuf {
    root.join("velora_bookshelf.json")
}

fn load_db(root: &PathBuf) -> BookshelfDb {
    let p = db_path(root);
    if !p.exists() {
        return BookshelfDb::default();
    }
    match fs::read_to_string(&p) {
        Ok(s) => serde_json::from_str(&s).unwrap_or_default(),
        Err(_) => BookshelfDb::default(),
    }
}

fn save_db(state: &StorageState) -> Result<()> {
    let p = db_path(&state.root);
    if let Some(parent) = p.parent() {
        fs::create_dir_all(parent)?;
    }
    let s = serde_json::to_string_pretty(&state.db)?;
    fs::write(p, s)?;
    Ok(())
}

#[flutter_rust_bridge::frb(sync)]
pub fn init_storage(root_dir: String) -> Result<()> {
    let root = PathBuf::from(&root_dir);
    fs::create_dir_all(&root)?;
    let db = load_db(&root);
    let _ = STATE.set(Mutex::new(StorageState { root, db }));
    Ok(())
}

fn with_state<F, R>(f: F) -> Result<R>
where
    F: FnOnce(&mut StorageState) -> Result<R>,
{
    let cell = STATE
        .get()
        .ok_or_else(|| anyhow!("存储未初始化，请先调用 init_storage"))?;
    let mut guard = cell.lock().map_err(|e| anyhow!("锁错误: {e}"))?;
    f(&mut guard)
}

#[flutter_rust_bridge::frb(sync)]
pub fn list_bookshelf() -> Result<Vec<BookshelfEntry>> {
    with_state(|s| Ok(s.db.entries.clone()))
}

#[flutter_rust_bridge::frb(sync)]
pub fn upsert_book(entry: BookshelfEntry) -> Result<()> {
    with_state(|s| {
        if let Some(item) = s.db.entries.iter_mut().find(|e| e.id == entry.id) {
            *item = entry;
        } else {
            s.db.entries.push(entry);
        }
        save_db(s)
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn remove_book(id: String) -> Result<()> {
    with_state(|s| {
        s.db.entries.retain(|e| e.id != id);
        save_db(s)
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn update_progress(id: String, chapter: u32, offset: u64, ts: i64) -> Result<()> {
    with_state(|s| {
        if let Some(item) = s.db.entries.iter_mut().find(|e| e.id == id) {
            item.last_chapter = chapter;
            item.last_offset = offset;
            item.updated_at = ts;
        }
        save_db(s)
    })
}
