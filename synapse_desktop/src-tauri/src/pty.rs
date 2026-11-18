//! A program in a pseudo-terminal. What a program prints comes as text and its end as an exit code, in
//! that order, through the callbacks it was started with; what a person types goes in with `write`.

use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};

/// What a pty reports, in order.
#[derive(Clone, Debug, PartialEq)]
pub enum PtyEvent {
    Data(String),
    Exit(i32),
}

/// What a started program is given.
#[derive(Clone, Debug)]
pub struct SpawnOptions {
    pub cwd: String,
    pub env: BTreeMap<String, String>,
    pub cols: u16,
    pub rows: u16,
}

/// A program that is running in a pty.
pub trait Pty: Send + Sync {
    fn write(&self, data: &str);
    fn resize(&self, cols: u16, rows: u16);
    fn kill(&self);
}

/// Where a pty's events go.
pub type OnEvent = Arc<dyn Fn(PtyEvent) + Send + Sync>;

/// Starts a program in a pty. A failure is the reason the program could not be started.
pub type SpawnPty = Arc<
    dyn Fn(&str, &[String], SpawnOptions, OnEvent) -> Result<Box<dyn Pty>, String> + Send + Sync,
>;

struct SystemPty {
    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    killer: Mutex<Box<dyn portable_pty::ChildKiller + Send + Sync>>,
}

impl Pty for SystemPty {
    fn write(&self, data: &str) {
        let mut writer = self.writer.lock().unwrap();
        let _ = writer.write_all(data.as_bytes());
        let _ = writer.flush();
    }

    fn resize(&self, cols: u16, rows: u16) {
        let _ = self.master.lock().unwrap().resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        });
    }

    fn kill(&self) {
        let _ = self.killer.lock().unwrap().kill();
    }
}

/// The text in `bytes` that is whole, and the end of it that is the start of a character not finished.
fn split_whole(bytes: &[u8]) -> usize {
    match std::str::from_utf8(bytes) {
        Ok(_) => bytes.len(),
        Err(error) if error.error_len().is_none() => error.valid_up_to(),
        // Bytes that are not text are given as they are, with the replacement character.
        Err(_) => bytes.len(),
    }
}

/// The real pty: the program runs in a pseudo-terminal of the system.
pub fn system_spawn() -> SpawnPty {
    Arc::new(|file, args, options, on_event| {
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: options.rows,
                cols: options.cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| e.to_string())?;
        let mut command = CommandBuilder::new(file);
        command.args(args);
        command.cwd(&options.cwd);
        command.env_clear();
        for (name, value) in &options.env {
            command.env(name, value);
        }
        // A shell launched in a folder knows it by the path it was given, not by the real one.
        if cfg!(unix) {
            command.env("PWD", &options.cwd);
        }
        let mut child = pair
            .slave
            .spawn_command(command)
            .map_err(|e| e.to_string())?;
        drop(pair.slave);
        let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
        let writer = pair.master.take_writer().map_err(|e| e.to_string())?;
        let killer = child.clone_killer();
        // One thread reads until the program's end, and then says how it ended, so that nothing it
        // printed comes after its exit.
        std::thread::spawn(move || {
            let mut pending: Vec<u8> = Vec::new();
            let mut chunk = [0u8; 16 * 1024];
            loop {
                match reader.read(&mut chunk) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        pending.extend_from_slice(&chunk[..n]);
                        let whole = split_whole(&pending);
                        if whole > 0 {
                            let text = String::from_utf8_lossy(&pending[..whole]).to_string();
                            pending.drain(..whole);
                            on_event(PtyEvent::Data(text));
                        }
                    }
                }
            }
            if !pending.is_empty() {
                on_event(PtyEvent::Data(
                    String::from_utf8_lossy(&pending).to_string(),
                ));
            }
            let code = child
                .wait()
                .map(|status| status.exit_code() as i32)
                .unwrap_or(1);
            on_event(PtyEvent::Exit(code));
        });
        Ok(Box::new(SystemPty {
            master: Mutex::new(pair.master),
            writer: Mutex::new(writer),
            killer: Mutex::new(killer),
        }))
    })
}
