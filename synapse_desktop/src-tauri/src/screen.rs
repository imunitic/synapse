//! What a terminal shows, kept as the program draws it, so that a client that attaches later is given the
//! screen and its scrollback and not a replay of the last bytes: a harness draws with cursor movement and
//! alternate screens, and a replay would start in the middle of a sequence.

/// How many lines above the screen are kept.
pub const SCROLLBACK_LINES: usize = 100;

pub struct Screen {
    parser: vt100::Parser,
}

impl Screen {
    pub fn new(cols: u16, rows: u16) -> Screen {
        Screen {
            parser: vt100::Parser::new(rows, cols, SCROLLBACK_LINES),
        }
    }

    /// What the program printed.
    pub fn write(&mut self, text: &str) {
        self.parser.process(text.as_bytes());
    }

    pub fn resize(&mut self, cols: u16, rows: u16) {
        self.parser.screen_mut().set_size(rows, cols);
    }

    /// Text that draws the screen as it is: the lines above it and the screen, with the cursor, the
    /// attributes and the modes the program set. On the alternate screen it is that screen, since the
    /// program drew it there.
    pub fn snapshot(&mut self) -> String {
        let screen = self.parser.screen_mut();
        let (_, cols) = screen.size();
        let mut out: Vec<u8> = Vec::new();
        if screen.alternate_screen() {
            out.extend_from_slice(b"\x1b[?1049h");
            out.extend_from_slice(&screen.contents_formatted());
        } else {
            // The lines above the screen, the oldest first: with the view moved up by `k` lines, the
            // first row is the k-th line above the screen.
            screen.set_scrollback(usize::MAX);
            let above = screen.scrollback();
            let mut lines: Vec<Vec<u8>> = Vec::new();
            for k in (1..=above).rev() {
                screen.set_scrollback(k);
                lines.extend(screen.rows_formatted(0, cols).take(1));
            }
            screen.set_scrollback(0);
            lines.extend(screen.rows_formatted(0, cols));
            out.extend_from_slice(b"\x1b[m");
            // Printed one after the other, the lines above the screen scroll off the top, which is
            // where a terminal keeps them.
            for (i, line) in lines.iter().enumerate() {
                if i > 0 {
                    out.extend_from_slice(b"\r\n");
                }
                out.extend_from_slice(line);
            }
            let (row, col) = screen.cursor_position();
            out.extend_from_slice(format!("\x1b[m\x1b[{};{}H", row + 1, col + 1).as_bytes());
        }
        out.extend_from_slice(&screen.input_mode_formatted());
        out.extend_from_slice(&screen.attributes_formatted());
        out.extend_from_slice(&screen.cursor_state_formatted());
        String::from_utf8_lossy(&out).to_string()
    }
}
