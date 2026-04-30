use crate::atspi_tree::{
    list_accessible_apps, snapshot_tree, AccessibilityNode, AccessibleAppSummary,
};
use crate::diagnostics::{doctor_report, setup_accessibility_report, DoctorReport, SetupReport};
use crate::screenshot::{capture_screenshot, ScreenshotCapture};
use anyhow::Result;
use rmcp::{
    handler::server::wrapper::{Json, Parameters},
    schemars::JsonSchema,
    tool, tool_handler, tool_router, ServerHandler, ServiceExt,
};
use serde::{Deserialize, Serialize};
use std::{
    env,
    path::PathBuf,
    process::{Command, Output},
    sync::{Arc, Mutex},
};

#[derive(Debug, Clone, Default)]
pub struct ComputerUseLinux {
    last_nodes: Arc<Mutex<Vec<AccessibilityNode>>>,
}

#[tool_router]
impl ComputerUseLinux {
    #[tool(
        name = "doctor",
        description = "Report Linux Computer Use desktop integration readiness."
    )]
    fn doctor(&self) -> Json<DoctorReport> {
        Json(doctor_report())
    }

    #[tool(
        name = "setup_accessibility",
        description = "Enable GNOME accessibility through gsettings so Linux Computer Use can read AT-SPI trees."
    )]
    fn setup_accessibility(&self) -> Json<SetupReport> {
        Json(setup_accessibility_report())
    }

    #[tool(
        name = "list_apps",
        description = "List running Linux desktop app candidates visible to the Computer Use backend."
    )]
    async fn list_apps(&self) -> Json<ListAppsOutput> {
        let (accessible_apps, accessibility_error) = match list_accessible_apps(50).await {
            Ok(apps) => (apps, None),
            Err(error) => (Vec::new(), Some(error.to_string())),
        };

        Json(ListAppsOutput {
            apps: list_process_apps(),
            accessible_apps,
            accessibility_error,
            note: "Linux Computer Use lists process candidates plus AT-SPI application roots when accessibility is enabled.".to_string(),
        })
    }

    #[tool(
        name = "get_app_state",
        description = "Start an app use session if needed, then get screenshot and accessibility state for a Linux app."
    )]
    async fn get_app_state(
        &self,
        Parameters(params): Parameters<GetAppStateParams>,
    ) -> Json<GetAppStateOutput> {
        let diagnostics = doctor_report();
        let max_nodes = params.max_nodes.unwrap_or(120).clamp(1, 500);
        let max_depth = params.max_depth.unwrap_or(12).min(12);
        let include_screenshot = params.include_screenshot.unwrap_or(true);
        let (screenshot, screenshot_error) = if include_screenshot {
            match capture_screenshot().await {
                Ok(capture) => (Some(capture), None),
                Err(error) => (None, Some(error.to_string())),
            }
        } else {
            (None, None)
        };
        let (accessibility_tree, accessibility_error) =
            if diagnostics.readiness.can_build_accessibility_tree {
                match snapshot_tree(
                    params.app_name_or_bundle_identifier.as_deref(),
                    max_nodes,
                    max_depth,
                )
                .await
                {
                    Ok(nodes) => (nodes, None),
                    Err(error) => (Vec::new(), Some(error.to_string())),
                }
            } else {
                (
                    Vec::new(),
                    Some(
                        "GNOME accessibility is disabled; call setup_accessibility first."
                            .to_string(),
                    ),
                )
            };
        if accessibility_error.is_none() {
            self.cache_nodes(&accessibility_tree);
        }
        let message = if let Some(error) = &accessibility_error {
            format!("MCP registration is working, but AT-SPI tree extraction failed: {error}")
        } else if let Some(capture) = &screenshot {
            format!(
                "MCP registration, screenshot capture, and AT-SPI tree extraction are working. Captured {} accessibility nodes and a screenshot through {}.",
                accessibility_tree.len(),
                capture.source
            )
        } else if let Some(error) = &screenshot_error {
            format!(
                "MCP registration and AT-SPI tree extraction are working. Captured {} accessibility nodes. Screenshot capture failed: {error}",
                accessibility_tree.len()
            )
        } else {
            format!(
                "MCP registration and AT-SPI tree extraction are working. Captured {} accessibility nodes. Screenshot capture was not requested.",
                accessibility_tree.len()
            )
        };

        Json(GetAppStateOutput {
            app_name_or_bundle_identifier: params.app_name_or_bundle_identifier,
            backend: "linux-atspi".to_string(),
            screenshot,
            screenshot_error,
            accessibility_tree,
            accessibility_error,
            diagnostics,
            message,
        })
    }

    #[tool(
        name = "click",
        description = "Click an element by index or pixel coordinates from screenshot."
    )]
    fn click(&self, Parameters(params): Parameters<ClickParams>) -> Json<ActionOutput> {
        let received = Some(serde_json::json!(params));
        let (x, y) = match self.resolve_target_point(params.x, params.y, params.element_index) {
            Ok(point) => point,
            Err(message) => {
                return Json(ActionOutput {
                    ok: false,
                    implemented: true,
                    action: "click".to_string(),
                    message,
                    received,
                });
            }
        };
        let button = mouse_button_code(params.button.as_deref());
        let click_count = params.click_count.unwrap_or(1).clamp(1, 10).to_string();
        let result = run_ydotool_sequence(&[
            absolute_mousemove_args(x, y),
            vec![
                "click".to_string(),
                "--repeat".to_string(),
                click_count,
                button,
            ],
        ]);
        Json(action_result("click", result, received))
    }

    #[tool(
        name = "perform_secondary_action",
        description = "Invoke a secondary accessibility action exposed by an element."
    )]
    fn perform_secondary_action(
        &self,
        Parameters(params): Parameters<SecondaryActionParams>,
    ) -> Json<ActionOutput> {
        Json(not_implemented(
            "perform_secondary_action",
            Some(serde_json::json!(params)),
            "AT-SPI secondary actions need the element action cache and are not wired yet.",
        ))
    }

    #[tool(
        name = "set_value",
        description = "Set the value of a settable accessibility element."
    )]
    fn set_value(&self, Parameters(params): Parameters<SetValueParams>) -> Json<ActionOutput> {
        Json(not_implemented(
            "set_value",
            Some(serde_json::json!(params)),
            "AT-SPI value setting needs the element value cache and is not wired yet.",
        ))
    }

    #[tool(
        name = "scroll",
        description = "Scroll an element in a direction by a number of pages."
    )]
    fn scroll(&self, Parameters(params): Parameters<ScrollParams>) -> Json<ActionOutput> {
        let received = Some(serde_json::json!(params));
        let units = ((params.pages.unwrap_or(1.0).abs().max(0.1) * 5.0).round() as i32).max(1);
        let target_point =
            match self.resolve_optional_target_point(params.x, params.y, params.element_index) {
                Ok(point) => point,
                Err(message) => {
                    return Json(ActionOutput {
                        ok: false,
                        implemented: true,
                        action: "scroll".to_string(),
                        message,
                        received,
                    });
                }
            };
        let (dx, dy) = match params.direction.to_ascii_lowercase().as_str() {
            "up" => (0, units),
            "down" => (0, -units),
            "left" => (units, 0),
            "right" => (-units, 0),
            _ => {
                return Json(ActionOutput {
                    ok: false,
                    implemented: true,
                    action: "scroll".to_string(),
                    message: "Unsupported scroll direction; expected up, down, left, or right."
                        .to_string(),
                    received,
                });
            }
        };
        let mut sequence = Vec::new();
        if let Some((x, y)) = target_point {
            sequence.push(absolute_mousemove_args(x, y));
        }
        sequence.push(vec![
            "mousemove".to_string(),
            "--wheel".to_string(),
            dx.to_string(),
            dy.to_string(),
        ]);
        let result = run_ydotool_sequence(&sequence);
        Json(action_result("scroll", result, received))
    }

    #[tool(
        name = "drag",
        description = "Drag from one point to another using pixel coordinates."
    )]
    fn drag(&self, Parameters(params): Parameters<DragParams>) -> Json<ActionOutput> {
        let received = Some(serde_json::json!(params));
        let result = run_ydotool_sequence(&[
            absolute_mousemove_args(params.start_x, params.start_y),
            vec!["click".to_string(), "0x40".to_string()],
            absolute_mousemove_args(params.end_x, params.end_y),
            vec!["click".to_string(), "0x80".to_string()],
        ]);
        Json(action_result("drag", result, received))
    }

    #[tool(
        name = "press_key",
        description = "Press a key or key-combination on the keyboard, including modifier and navigation keys."
    )]
    fn press_key(&self, Parameters(params): Parameters<PressKeyParams>) -> Json<ActionOutput> {
        let received = Some(serde_json::json!(params));
        let Some(key_events) = key_sequence(&params.key) else {
            return Json(ActionOutput {
                ok: false,
                implemented: true,
                action: "press_key".to_string(),
                message: "Unsupported key. Use names like Enter, Escape, Tab, ArrowLeft, Super, Ctrl+L, or a single US keyboard letter/digit.".to_string(),
                received,
            });
        };
        let mut args = vec!["key".to_string()];
        args.extend(key_events);
        let result = run_ydotool(&args).map(|output| vec![output]);
        Json(action_result("press_key", result, received))
    }

    #[tool(
        name = "type_text",
        description = "Type literal text using keyboard input."
    )]
    fn type_text(&self, Parameters(params): Parameters<TypeTextParams>) -> Json<ActionOutput> {
        let received = Some(serde_json::json!(params));
        let result = run_ydotool(&["type".to_string(), "--".to_string(), params.text])
            .map(|output| vec![output]);
        Json(action_result("type_text", result, received))
    }
}

#[tool_handler(
    name = "codex-computer-use-linux",
    version = "0.1.0",
    instructions = "Begin every turn that uses Computer Use by calling get_app_state. If diagnostics report disabled GNOME accessibility, call setup_accessibility before asking the user to retry. This Linux backend can capture screenshots through GNOME Shell or XDG Desktop Portal, read AT-SPI trees, and send coordinate, element-index click/scroll, key, text, and drag input through ydotool when ydotoold is available. Native AT-SPI actions are still in progress."
)]
impl ServerHandler for ComputerUseLinux {}

pub async fn serve_mcp() -> Result<()> {
    ComputerUseLinux::default()
        .serve(rmcp::transport::stdio())
        .await?
        .waiting()
        .await?;
    Ok(())
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
struct ListAppsOutput {
    apps: Vec<AppCandidate>,
    accessible_apps: Vec<AccessibleAppSummary>,
    accessibility_error: Option<String>,
    note: String,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
struct AppCandidate {
    name: String,
    pid: u32,
    command: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
struct GetAppStateParams {
    #[serde(default)]
    app_name_or_bundle_identifier: Option<String>,
    #[serde(default)]
    max_nodes: Option<usize>,
    #[serde(default)]
    max_depth: Option<u32>,
    #[serde(default)]
    include_screenshot: Option<bool>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
struct GetAppStateOutput {
    app_name_or_bundle_identifier: Option<String>,
    backend: String,
    screenshot: Option<ScreenshotCapture>,
    screenshot_error: Option<String>,
    accessibility_tree: Vec<AccessibilityNode>,
    accessibility_error: Option<String>,
    diagnostics: DoctorReport,
    message: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
struct ClickParams {
    #[serde(default)]
    element_index: Option<u32>,
    #[serde(default)]
    x: Option<i32>,
    #[serde(default)]
    y: Option<i32>,
    #[serde(default)]
    button: Option<String>,
    #[serde(default)]
    click_count: Option<u32>,
}

#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
struct SecondaryActionParams {
    #[serde(default)]
    element_index: Option<u32>,
    #[serde(default)]
    element_identifier: Option<String>,
    #[serde(default)]
    action: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
struct SetValueParams {
    #[serde(default)]
    element_index: Option<u32>,
    #[serde(default)]
    element_identifier: Option<String>,
    value: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
struct ScrollParams {
    #[serde(default)]
    element_index: Option<u32>,
    #[serde(default)]
    x: Option<i32>,
    #[serde(default)]
    y: Option<i32>,
    direction: String,
    #[serde(default)]
    pages: Option<f64>,
}

#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
struct DragParams {
    start_x: i32,
    start_y: i32,
    end_x: i32,
    end_y: i32,
}

#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
struct PressKeyParams {
    key: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
struct TypeTextParams {
    text: String,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
struct ActionOutput {
    ok: bool,
    implemented: bool,
    action: String,
    message: String,
    received: Option<serde_json::Value>,
}

fn not_implemented(
    action: &str,
    received: Option<serde_json::Value>,
    message: &str,
) -> ActionOutput {
    ActionOutput {
        ok: false,
        implemented: false,
        action: action.to_string(),
        message: message.to_string(),
        received,
    }
}

impl ComputerUseLinux {
    fn cache_nodes(&self, nodes: &[AccessibilityNode]) {
        if let Ok(mut cached) = self.last_nodes.lock() {
            cached.clear();
            cached.extend_from_slice(nodes);
        }
    }

    fn resolve_target_point(
        &self,
        x: Option<i32>,
        y: Option<i32>,
        element_index: Option<u32>,
    ) -> std::result::Result<(i32, i32), String> {
        self.resolve_optional_target_point(x, y, element_index)?
            .ok_or_else(|| {
                "Pass x/y coordinates or an element_index from the latest get_app_state result."
                    .to_string()
            })
    }

    fn resolve_optional_target_point(
        &self,
        x: Option<i32>,
        y: Option<i32>,
        element_index: Option<u32>,
    ) -> std::result::Result<Option<(i32, i32)>, String> {
        match (x.zip(y), element_index) {
            (Some(point), _) => Ok(Some(point)),
            (None, Some(index)) => self
                .center_for_cached_node(index)
                .map(Some)
                .ok_or_else(|| {
                    format!(
                        "No clickable bounds cached for element_index {index}. Call get_app_state first and choose a node with positive width and height."
                    )
                }),
            (None, None) => Ok(None),
        }
    }

    fn center_for_cached_node(&self, element_index: u32) -> Option<(i32, i32)> {
        let cached = self.last_nodes.lock().ok()?;
        let node = cached.iter().find(|node| node.index == element_index)?;
        let bounds = node.bounds.as_ref()?;
        if bounds.width <= 0 || bounds.height <= 0 {
            return None;
        }
        Some((bounds.x + bounds.width / 2, bounds.y + bounds.height / 2))
    }
}

fn action_result(
    action: &str,
    result: std::result::Result<Vec<Output>, String>,
    received: Option<serde_json::Value>,
) -> ActionOutput {
    match result {
        Ok(_) => ActionOutput {
            ok: true,
            implemented: true,
            action: action.to_string(),
            message: "Action sent through ydotool.".to_string(),
            received,
        },
        Err(message) => ActionOutput {
            ok: false,
            implemented: true,
            action: action.to_string(),
            message,
            received,
        },
    }
}

fn absolute_mousemove_args(x: i32, y: i32) -> Vec<String> {
    vec![
        "mousemove".to_string(),
        "--absolute".to_string(),
        "--".to_string(),
        x.to_string(),
        y.to_string(),
    ]
}

fn run_ydotool_sequence(commands: &[Vec<String>]) -> std::result::Result<Vec<Output>, String> {
    let mut outputs = Vec::new();
    for args in commands {
        outputs.push(run_ydotool(args)?);
    }
    Ok(outputs)
}

fn run_ydotool(args: &[String]) -> std::result::Result<Output, String> {
    let mut command = Command::new("ydotool");
    command.args(args);
    if let Some(socket) = ydotool_socket() {
        command.env("YDOTOOL_SOCKET", socket);
    }

    match command.output() {
        Ok(output) if output.status.success() => Ok(output),
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
            let detail = if stderr.is_empty() { stdout } else { stderr };
            Err(if detail.is_empty() {
                format!("ydotool exited with {}", output.status)
            } else {
                detail
            })
        }
        Err(error) => Err(format!("failed to run ydotool: {error}")),
    }
}

fn ydotool_socket() -> Option<String> {
    if let Ok(socket) = env::var("YDOTOOL_SOCKET") {
        if !socket.trim().is_empty() {
            return Some(socket);
        }
    }

    let candidates = [
        env::var("XDG_RUNTIME_DIR")
            .ok()
            .map(PathBuf::from)
            .or_else(|| user_id().map(|uid| PathBuf::from(format!("/run/user/{uid}"))))
            .map(|runtime| runtime.join(".ydotool_socket")),
        Some(PathBuf::from("/tmp/.ydotool_socket")),
    ];

    candidates
        .into_iter()
        .flatten()
        .find(|path| path.exists())
        .map(|path| path.display().to_string())
}

fn mouse_button_code(button: Option<&str>) -> String {
    match button.unwrap_or("left").to_ascii_lowercase().as_str() {
        "right" => "0xC1",
        "middle" => "0xC2",
        "side" => "0xC3",
        "extra" => "0xC4",
        "forward" => "0xC5",
        "back" => "0xC6",
        _ => "0xC0",
    }
    .to_string()
}

fn key_sequence(key: &str) -> Option<Vec<String>> {
    let parts = key
        .split('+')
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>();
    let (key_part, modifier_parts) = parts.split_last()?;
    if modifier_parts.is_empty() {
        if let Some(modifier) = modifier_keycode(key_part) {
            return Some(vec![format!("{modifier}:1"), format!("{modifier}:0")]);
        }
    }
    let mut modifiers = Vec::new();
    for part in modifier_parts {
        modifiers.push(modifier_keycode(part)?);
    }
    let keycode = keycode(key_part)?;

    let mut events = Vec::new();
    for modifier in &modifiers {
        events.push(format!("{modifier}:1"));
    }
    events.push(format!("{keycode}:1"));
    events.push(format!("{keycode}:0"));
    for modifier in modifiers.iter().rev() {
        events.push(format!("{modifier}:0"));
    }
    Some(events)
}

fn modifier_keycode(key: &str) -> Option<u16> {
    match normalize_key(key).as_str() {
        "ctrl" | "control" => Some(29),
        "alt" | "option" => Some(56),
        "shift" => Some(42),
        "meta" | "super" | "cmd" | "command" => Some(125),
        _ => None,
    }
}

fn keycode(key: &str) -> Option<u16> {
    match normalize_key(key).as_str() {
        "enter" | "return" => Some(28),
        "escape" | "esc" => Some(1),
        "tab" => Some(15),
        "backspace" => Some(14),
        "delete" | "del" => Some(111),
        "space" => Some(57),
        "home" => Some(102),
        "end" => Some(107),
        "pageup" | "page_up" => Some(104),
        "pagedown" | "page_down" => Some(109),
        "arrowleft" | "left" => Some(105),
        "arrowright" | "right" => Some(106),
        "arrowup" | "up" => Some(103),
        "arrowdown" | "down" => Some(108),
        "f1" => Some(59),
        "f2" => Some(60),
        "f3" => Some(61),
        "f4" => Some(62),
        "f5" => Some(63),
        "f6" => Some(64),
        "f7" => Some(65),
        "f8" => Some(66),
        "f9" => Some(67),
        "f10" => Some(68),
        "f11" => Some(87),
        "f12" => Some(88),
        value if value.len() == 1 => keycode_for_ascii(value.as_bytes()[0] as char),
        _ => None,
    }
}

fn normalize_key(key: &str) -> String {
    key.trim().to_ascii_lowercase().replace(['-', ' '], "")
}

fn keycode_for_ascii(value: char) -> Option<u16> {
    match value {
        'a' => Some(30),
        'b' => Some(48),
        'c' => Some(46),
        'd' => Some(32),
        'e' => Some(18),
        'f' => Some(33),
        'g' => Some(34),
        'h' => Some(35),
        'i' => Some(23),
        'j' => Some(36),
        'k' => Some(37),
        'l' => Some(38),
        'm' => Some(50),
        'n' => Some(49),
        'o' => Some(24),
        'p' => Some(25),
        'q' => Some(16),
        'r' => Some(19),
        's' => Some(31),
        't' => Some(20),
        'u' => Some(22),
        'v' => Some(47),
        'w' => Some(17),
        'x' => Some(45),
        'y' => Some(21),
        'z' => Some(44),
        '1' => Some(2),
        '2' => Some(3),
        '3' => Some(4),
        '4' => Some(5),
        '5' => Some(6),
        '6' => Some(7),
        '7' => Some(8),
        '8' => Some(9),
        '9' => Some(10),
        '0' => Some(11),
        _ => None,
    }
}

fn user_id() -> Option<String> {
    let output = Command::new("id").arg("-u").output().ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .filter(|value| !value.is_empty())
}

fn list_process_apps() -> Vec<AppCandidate> {
    let output = Command::new("ps")
        .args(["-eo", "pid=,comm=,args="])
        .output();
    let Ok(output) = output else {
        return Vec::new();
    };
    if !output.status.success() {
        return Vec::new();
    }

    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(parse_process_line)
        .filter(|app| looks_like_desktop_app(&app.name, &app.command))
        .take(50)
        .collect()
}

fn parse_process_line(line: &str) -> Option<AppCandidate> {
    let trimmed = line.trim();
    let mut parts = trimmed.splitn(3, char::is_whitespace);
    let pid = parts.next()?.parse().ok()?;
    let name = parts.next()?.to_string();
    let command = parts.next().unwrap_or("").trim().to_string();
    Some(AppCandidate { name, pid, command })
}

fn looks_like_desktop_app(name: &str, command: &str) -> bool {
    let haystack = format!("{name} {command}").to_ascii_lowercase();
    [
        "codex",
        "electron",
        "chrome",
        "chromium",
        "firefox",
        "brave",
        "code",
        "gnome-terminal",
        "ptyxis",
        "kgx",
        "nautilus",
        "slack",
        "discord",
        "spotify",
        "obsidian",
    ]
    .iter()
    .any(|needle| haystack.contains(needle))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atspi_tree::Bounds;

    fn node(index: u32, bounds: Option<Bounds>) -> AccessibilityNode {
        AccessibilityNode {
            index,
            parent_index: None,
            depth: 0,
            object_ref: format!(":1.{index}/org/a11y/atspi/accessible/{index}"),
            role: "push button".to_string(),
            name: Some(format!("Button {index}")),
            description: None,
            child_count: 0,
            bounds,
        }
    }

    #[test]
    fn cached_element_index_resolves_to_bounds_center() {
        let backend = ComputerUseLinux::default();
        backend.cache_nodes(&[node(
            7,
            Some(Bounds {
                x: 10,
                y: 20,
                width: 100,
                height: 40,
            }),
        )]);

        let point = backend.resolve_target_point(None, None, Some(7)).unwrap();

        assert_eq!(point, (60, 40));
    }

    #[test]
    fn coordinate_target_overrides_cached_element_index() {
        let backend = ComputerUseLinux::default();
        backend.cache_nodes(&[node(
            7,
            Some(Bounds {
                x: 10,
                y: 20,
                width: 100,
                height: 40,
            }),
        )]);

        let point = backend
            .resolve_target_point(Some(200), Some(300), Some(7))
            .unwrap();

        assert_eq!(point, (200, 300));
    }

    #[test]
    fn cached_element_index_requires_positive_bounds() {
        let backend = ComputerUseLinux::default();
        backend.cache_nodes(&[node(
            7,
            Some(Bounds {
                x: 10,
                y: 20,
                width: 0,
                height: 40,
            }),
        )]);

        let error = backend
            .resolve_target_point(None, None, Some(7))
            .unwrap_err();

        assert!(error.contains("No clickable bounds cached for element_index 7"));
    }

    #[test]
    fn absolute_mousemove_uses_coordinate_separator() {
        assert_eq!(
            absolute_mousemove_args(200, 300),
            vec![
                "mousemove".to_string(),
                "--absolute".to_string(),
                "--".to_string(),
                "200".to_string(),
                "300".to_string(),
            ]
        );
    }

    #[test]
    fn key_sequence_presses_modifiers_around_key() {
        assert_eq!(
            key_sequence("Ctrl+Shift+P"),
            Some(vec![
                "29:1".to_string(),
                "42:1".to_string(),
                "25:1".to_string(),
                "25:0".to_string(),
                "42:0".to_string(),
                "29:0".to_string(),
            ])
        );
    }

    #[test]
    fn key_sequence_presses_bare_modifier() {
        assert_eq!(
            key_sequence("Super"),
            Some(vec!["125:1".to_string(), "125:0".to_string()])
        );
    }
}
