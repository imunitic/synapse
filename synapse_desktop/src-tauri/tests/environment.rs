//! Where things are: the folders the file messages may reach, `~` in a typed path, and the places
//! Synapse keeps its files.

// Some cases name Unix paths; what only they use is unused on Windows.
#![cfg_attr(windows, allow(unused_imports, dead_code))]

mod support;

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use support::environment;
use synapse_desktop_host::config::expand_config_paths;
use synapse_desktop_host::environment::{
    allowed_roots, conf_file, definition_dirs, expand_home, resolve_inside,
};
use synapse_desktop_host::messages::AppConfig;
use synapse_desktop_host::protocol::ErrorCode;
use tempfile::tempdir;

fn s(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

#[test]
fn a_file_inside_a_root_is_accepted() {
    let dir = tempdir().unwrap();
    let root = dir.path().join("root");
    fs::create_dir(&root).unwrap();
    fs::write(root.join("a.synapse"), "x").unwrap();
    let real = resolve_inside(&s(&root.join("a.synapse")), &[root]).unwrap();
    assert!(real.ends_with("a.synapse"));
}

#[test]
fn a_file_outside_every_root_a_climb_a_link_a_sibling_and_a_relative_path_are_refused() {
    let dir = tempdir().unwrap();
    let root = dir.path().join("root");
    let sibling = dir.path().join("root-other");
    fs::create_dir(&root).unwrap();
    fs::create_dir(&sibling).unwrap();
    fs::write(dir.path().join("secret"), "x").unwrap();
    fs::write(sibling.join("f"), "x").unwrap();
    let roots = [root.clone()];
    let refused = |target: String| {
        let error = resolve_inside(&target, &roots).unwrap_err();
        assert_eq!(error.code, ErrorCode::Forbidden, "{target}");
    };
    refused(s(&dir.path().join("secret")));
    refused(s(&root.join("..").join("secret")));
    refused(s(&sibling.join("f")));
    refused("a.synapse".into());
    refused(s(&root.join("missing")));
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(dir.path().join("secret"), root.join("link")).unwrap();
        refused(s(&root.join("link")));
    }
}

#[cfg(unix)]
#[test]
fn the_definition_folders_are_the_variable_the_default_and_the_configured() {
    let environment = environment(
        Path::new("/home/u"),
        &[("SYNAPSE_PIPELINE_PATH", "/x/one:/x/two")],
    );
    let dirs = definition_dirs(&["/y/three".into()], &environment);
    let expected: Vec<PathBuf> = [
        "/x/one",
        "/x/two",
        "/home/u/.config/synapse-pipeline",
        "/y/three",
    ]
    .map(PathBuf::from)
    .to_vec();
    assert_eq!(dirs, expected);

    let xdg = self::environment(Path::new("/home/u"), &[("XDG_CONFIG_HOME", "/xdg")]);
    assert_eq!(
        definition_dirs(&[], &xdg),
        vec![PathBuf::from("/xdg/synapse-pipeline")]
    );
}

#[test]
fn only_the_pipelines_folder_of_the_work_directory_is_reached() {
    let environment = environment(Path::new("/home/u"), &[]);
    let roots = allowed_roots(&[], Some("/work"), &environment);
    assert!(roots.contains(&PathBuf::from("/work/pipelines")));
    assert!(!roots.contains(&PathBuf::from("/work")));
}

#[cfg(unix)]
#[test]
fn a_path_with_a_tilde_is_the_home_folder_or_a_path_in_it_and_otherwise_left_alone() {
    let home = Path::new("/Users/me");
    assert_eq!(expand_home("~", home), "/Users/me");
    assert_eq!(
        expand_home("~/Development/synapse", home),
        "/Users/me/Development/synapse"
    );
    assert_eq!(expand_home("~\\Development", home), "/Users/me/Development");
    for same in ["/a/~/b", "~other/x", "C:/Users/RUNNER~1/x", "relative/path"] {
        assert_eq!(expand_home(same, home), same);
    }
    // With no home there is nothing to put in.
    assert_eq!(expand_home("~/x", Path::new("")), "~/x");
}

#[cfg(unix)]
#[test]
fn the_settings_that_hold_a_folder_have_the_tilde_expanded_and_the_others_stay() {
    let config = AppConfig {
        work_dir: Some("~/.cache/synapse/work".into()),
        definition_paths: vec!["~/defs".into(), "/abs/defs".into()],
        default_harness: None,
        default_models: BTreeMap::new(),
        default_efforts: BTreeMap::new(),
        env: BTreeMap::from([("KEEP".into(), "~/not-a-path".into())]),
        recent_vaults: vec![],
        terminal_folder: Some("~".into()),
        graph_repos: BTreeMap::from([("a@main".into(), "~/code/a".into())]),
    };
    let expanded = expand_config_paths(config, Path::new("/Users/me"));
    assert_eq!(
        expanded.work_dir.as_deref(),
        Some("/Users/me/.cache/synapse/work")
    );
    assert_eq!(
        expanded.definition_paths,
        vec!["/Users/me/defs", "/abs/defs"]
    );
    assert_eq!(expanded.terminal_folder.as_deref(), Some("/Users/me"));
    assert_eq!(expanded.graph_repos["a@main"], "/Users/me/code/a");
    assert_eq!(expanded.env["KEEP"], "~/not-a-path");
}

#[test]
fn a_conf_file_is_under_xdg_config_home_else_dot_config_when_there_is_one_and_else_dot_claude() {
    let dir = tempdir().unwrap();
    let home = dir.path();
    let xdg = home.join("xdg");
    fs::create_dir_all(xdg.join("synapse")).unwrap();
    fs::write(xdg.join("synapse/x.conf"), "a=b\n").unwrap();
    assert_eq!(
        conf_file(
            &environment(home, &[("XDG_CONFIG_HOME", &s(&xdg))]),
            "x.conf"
        ),
        xdg.join("synapse/x.conf")
    );

    fs::create_dir_all(home.join(".config/synapse")).unwrap();
    fs::write(home.join(".config/synapse/x.conf"), "c=d\n").unwrap();
    assert_eq!(
        conf_file(&environment(home, &[]), "x.conf"),
        home.join(".config/synapse/x.conf")
    );
    fs::remove_dir_all(home.join(".config")).unwrap();

    // Not under ~/.config now: ~/.claude has it, then none does.
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::write(home.join(".claude/x.conf"), "a=b\n").unwrap();
    assert_eq!(
        conf_file(&environment(home, &[]), "x.conf"),
        home.join(".claude/x.conf")
    );
    fs::remove_dir_all(home.join(".claude")).unwrap();
    assert_eq!(
        conf_file(&environment(home, &[]), "x.conf"),
        home.join(".claude/x.conf")
    );
    // With a ~/.config it is made there.
    fs::create_dir(home.join(".config")).unwrap();
    assert_eq!(
        conf_file(&environment(home, &[]), "x.conf"),
        home.join(".config/synapse/x.conf")
    );
}
