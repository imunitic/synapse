//! What a folder that may be a vault looks like, for the page that switches the vault, and making a
//! folder one.

use crate::dispatch::HostError;
use crate::messages::VaultInfo;
use std::fs;
use std::path::Path;

/// A walk stops after this many entries, so a folder that is not a vault, such as a home folder, does
/// not keep the app busy.
const MAX_ENTRIES: usize = 20_000;

/// Notes are Markdown files. Folders that start with a dot, such as `.git` and `.obsidian`, hold no
/// notes.
fn count_notes(root: &Path) -> (u64, bool) {
    let mut notes = 0;
    let mut seen = 0;
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        for entry in fs::read_dir(&dir).into_iter().flatten().flatten() {
            seen += 1;
            if seen > MAX_ENTRIES {
                return (notes, true);
            }
            let name = entry.file_name().to_string_lossy().to_string();
            // A link to a folder or a file is what it points to, as when a person looks at it.
            let Ok(kind) = fs::metadata(entry.path()) else {
                continue;
            };
            if kind.is_dir() {
                if !name.starts_with('.') {
                    pending.push(entry.path());
                }
            } else if kind.is_file() && name.ends_with(".md") {
                notes += 1;
            }
        }
    }
    (notes, false)
}

/// What the folder at `path` is: whether it is there, has an `Index.md` and is a git repository, and
/// how many notes it holds.
pub fn inspect_vault(path: &str) -> VaultInfo {
    let folder = Path::new(path);
    if !folder.is_dir() {
        return VaultInfo {
            path: path.into(),
            exists: false,
            has_index: false,
            is_git: false,
            notes: 0,
            capped: false,
        };
    }
    let (notes, capped) = count_notes(folder);
    VaultInfo {
        path: path.into(),
        exists: true,
        has_index: folder.join("Index.md").is_file(),
        is_git: folder.join(".git").is_dir(),
        notes,
        capped,
    }
}

/// Makes a folder a vault: the folder, and an `Index.md` made from the template the package ships when
/// there is none. What is in the folder is left as it is, the `Index.md` of a vault that has one
/// included.
pub fn seed_vault(path: &str, template: Option<&Path>) -> Result<(), HostError> {
    let folder = Path::new(path);
    if folder.exists() && !folder.is_dir() {
        return Err(HostError::conflict(format!("{path} is not a folder")));
    }
    let index = folder.join("Index.md");
    let seeded = index.is_file();
    // Nothing is made when what it is made from is not there.
    let template = template.filter(|t| t.is_file());
    if !seeded && template.is_none() {
        return Err(HostError::conflict(
            "The Index.md template of Synapse was not found.",
        ));
    }
    fs::create_dir_all(folder).map_err(|e| HostError::internal(e.to_string()))?;
    if seeded {
        return Ok(());
    }
    let text = fs::read(template.unwrap_or(Path::new("")))
        .map_err(|e| HostError::internal(e.to_string()))?;
    // `create_new`: a file that appeared meanwhile is not written over.
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&index)
    {
        Ok(mut file) => {
            use std::io::Write;
            file.write_all(&text)
                .map_err(|e| HostError::internal(e.to_string()))
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
        Err(e) => Err(HostError::internal(e.to_string())),
    }
}
