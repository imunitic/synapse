//! The screen a terminal keeps, so that a snapshot draws it as the program did.

use synapse_desktop_host::screen::Screen;

#[test]
fn a_snapshot_holds_the_lines_above_the_screen_the_screen_and_its_attributes() {
    let mut screen = Screen::new(20, 4);
    screen.write("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n\x1b[31mred\x1b[0m");
    let data = screen.snapshot();
    for needle in ["one\r\ntwo\r\nthree", "\x1b[31mred"] {
        assert!(data.contains(needle), "{data:?}");
    }
}

#[test]
fn the_alternate_screen_is_kept_with_the_mode_that_selects_it() {
    let mut screen = Screen::new(20, 4);
    screen.write("\x1b[?1049h\x1b[2J\x1b[HALT SCREEN");
    let data = screen.snapshot();
    assert!(data.starts_with("\x1b[?1049h"), "{data:?}");
    assert!(data.contains("ALT SCREEN"));
}

#[test]
fn a_resize_changes_what_the_next_snapshot_is_drawn_at() {
    let mut screen = Screen::new(20, 4);
    screen.write("abc");
    screen.resize(40, 10);
    assert!(screen.snapshot().contains("abc"));
}
