//! The efforts each harness offers, the arguments that ask a harness for a model and an effort, and
//! the harness, model and effort an agent run of the app uses. The same values and rules as the Node
//! host's `shared/efforts.ts`, `server/harness-args.ts` and `choiceOf` in `server/calls.ts`.

use crate::dispatch::HostError;
use crate::messages::{AppConfig, Harness};
use regex::Regex;
use std::sync::OnceLock;

/// Claude's `--effort` values.
pub const CLAUDE_EFFORTS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];
/// Codex's `model_reasoning_effort` values: the names its `ReasoningEffort` enum knows.
pub const CODEX_EFFORTS: [&str; 9] = [
    "none",
    "minimal",
    "low",
    "medium",
    "high",
    "xhigh",
    "max",
    "ultra",
    "persistent",
];

/// An OpenCode variant: named by the model, so any name of this shape. It starts with a letter or a
/// digit, so that it cannot be taken for a flag, and holds no `#`, which separates it from the model.
/// Every effort of the lists has this shape too.
pub fn is_variant_name(name: &str) -> bool {
    static CELL: OnceLock<Regex> = OnceLock::new();
    CELL.get_or_init(|| Regex::new(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$").unwrap())
        .is_match(name)
}

/// The efforts a harness offers, in order; none for OpenCode, whose variant is typed.
pub fn efforts_of(harness: Harness) -> Option<&'static [&'static str]> {
    match harness {
        Harness::Claude => Some(&CLAUDE_EFFORTS),
        Harness::Codex => Some(&CODEX_EFFORTS),
        Harness::Opencode => None,
    }
}

/// Whether the harness takes this effort.
pub fn is_effort_for(harness: Harness, effort: &str) -> bool {
    match efforts_of(harness) {
        Some(efforts) => efforts.contains(&effort),
        None => is_variant_name(effort),
    }
}

/// The arguments that ask a harness for a model and an effort: Claude `--model M --effort E`, Codex
/// `-m M -c model_reasoning_effort="E"`, OpenCode `-m M#E`. Nothing for what is absent. OpenCode
/// takes the variant only as part of a model, so an effort without one adds nothing; `choice_of`
/// refuses that case before it gets here.
pub fn model_args(harness: Harness, model: Option<&str>, effort: Option<&str>) -> Vec<String> {
    let pair = |flag: &str, value: Option<String>| -> Vec<String> {
        value
            .into_iter()
            .flat_map(|v| [flag.to_string(), v])
            .collect()
    };
    match harness {
        Harness::Claude => [
            pair("--model", model.map(String::from)),
            pair("--effort", effort.map(String::from)),
        ]
        .concat(),
        Harness::Codex => [
            pair("-m", model.map(String::from)),
            pair(
                "-c",
                effort.map(|e| format!("model_reasoning_effort=\"{e}\"")),
            ),
        ]
        .concat(),
        Harness::Opencode => pair(
            "-m",
            model.map(|m| match effort {
                Some(e) => format!("{m}#{e}"),
                None => m.to_string(),
            }),
        ),
    }
}

/// The harness, model and effort an agent run of the app uses.
#[derive(Clone, Debug, PartialEq)]
pub struct RunChoice {
    pub harness: Harness,
    pub model: Option<String>,
    pub effort: Option<String>,
}

/// The harness, model and effort of a request: what it names, else the defaults of the config. An
/// effort the harness does not offer is refused. OpenCode takes its variant only as part of a model,
/// so without one a request's own effort is refused and a default one is dropped.
pub fn choice_of(
    harness: Option<Harness>,
    model: Option<&String>,
    effort: Option<&String>,
    config: &AppConfig,
) -> Result<RunChoice, HostError> {
    let harness = harness
        .or(config.default_harness)
        .unwrap_or(Harness::Claude);
    let model = model
        .cloned()
        .or_else(|| config.default_models.get(&harness).cloned());
    let mut chosen = effort
        .cloned()
        .or_else(|| config.default_efforts.get(&harness).cloned());
    if let Some(value) = &chosen {
        if !is_effort_for(harness, value) {
            return Err(HostError::bad_request(format!(
                "{harness:?} does not offer effort '{value}'"
            )));
        }
    }
    if harness == Harness::Opencode && model.is_none() && chosen.is_some() {
        if effort.is_some() {
            return Err(HostError::bad_request("an OpenCode variant needs a model"));
        }
        chosen = None;
    }
    Ok(RunChoice {
        harness,
        model,
        effort: chosen,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_is_given_the_model_then_the_effort() {
        assert_eq!(
            model_args(Harness::Claude, Some("opus"), Some("high")),
            ["--model", "opus", "--effort", "high"]
        );
        assert_eq!(
            model_args(Harness::Claude, None, Some("high")),
            ["--effort", "high"]
        );
    }

    #[test]
    fn codex_is_given_the_effort_as_a_config_value() {
        assert_eq!(
            model_args(Harness::Codex, Some("gpt-x"), Some("xhigh")),
            ["-m", "gpt-x", "-c", "model_reasoning_effort=\"xhigh\""]
        );
        assert_eq!(
            model_args(Harness::Codex, None, Some("xhigh")),
            ["-c", "model_reasoning_effort=\"xhigh\""]
        );
    }

    #[test]
    fn opencode_is_given_the_variant_as_part_of_the_model() {
        assert_eq!(
            model_args(Harness::Opencode, Some("prov/model"), Some("high")),
            ["-m", "prov/model#high"]
        );
        assert!(model_args(Harness::Opencode, None, Some("high")).is_empty());
    }

    #[test]
    fn neither_a_model_nor_an_effort_adds_no_argument() {
        for harness in [Harness::Claude, Harness::Codex, Harness::Opencode] {
            assert!(model_args(harness, None, None).is_empty());
        }
    }

    #[test]
    fn claude_offers_its_five_efforts() {
        for effort in CLAUDE_EFFORTS {
            assert!(is_effort_for(Harness::Claude, effort));
        }
        assert!(!is_effort_for(Harness::Claude, "minimal"));
    }

    #[test]
    fn codex_offers_minimal_and_max_but_not_an_unknown_name() {
        assert!(is_effort_for(Harness::Codex, "minimal"));
        assert!(is_effort_for(Harness::Codex, "max"));
        assert!(!is_effort_for(Harness::Codex, "extreme"));
    }

    #[test]
    fn opencode_takes_any_variant_name_but_not_a_leading_dash_or_a_hash() {
        assert!(is_effort_for(Harness::Opencode, "thinking-max.2"));
        for bad in ["", "-high", "a#b"] {
            assert!(!is_effort_for(Harness::Opencode, bad), "{bad:?}");
        }
    }
}
