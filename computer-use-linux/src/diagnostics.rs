use schemars::JsonSchema;
use serde::Serialize;
use std::{
    env,
    path::{Path, PathBuf},
    process::Command,
};

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct DoctorReport {
    pub platform: PlatformReport,
    pub portals: PortalReport,
    pub accessibility: AccessibilityReport,
    pub input: InputReport,
    pub readiness: ReadinessReport,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct PlatformReport {
    pub os: String,
    pub arch: String,
    pub desktop_session: Option<String>,
    pub xdg_session_type: Option<String>,
    pub xdg_current_desktop: Option<String>,
    pub wayland_display: Option<String>,
    pub display: Option<String>,
    pub dbus_session_bus_address: Option<String>,
    pub xdg_runtime_dir: Option<String>,
    pub gnome_shell_version: Check,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct PortalReport {
    pub desktop_portal: Check,
    pub remote_desktop: Check,
    pub screencast: Check,
    pub screenshot: Check,
    pub input_capture: Check,
    pub mutter_remote_desktop: Check,
    pub mutter_screencast: Check,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct AccessibilityReport {
    pub at_spi_bus: Check,
    pub toolkit_accessibility: Check,
    pub at_spi_enabled: Check,
    pub screen_reader_enabled: Check,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct InputReport {
    pub ydotool: Check,
    pub ydotoold: Check,
    pub ydotool_socket: Check,
    pub uinput: Check,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct ReadinessReport {
    pub can_register_mcp_tools: bool,
    pub can_build_accessibility_tree: bool,
    pub can_send_development_input: bool,
    pub recommended_next_step: String,
    pub blockers: Vec<String>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct SetupReport {
    pub before: DoctorReport,
    pub accessibility_command: Check,
    pub after: DoctorReport,
    pub changed_accessibility: bool,
    pub requires_target_app_restart: bool,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct Check {
    pub ok: bool,
    pub detail: String,
}

impl Check {
    fn ok(detail: impl Into<String>) -> Self {
        Self {
            ok: true,
            detail: detail.into(),
        }
    }

    fn fail(detail: impl Into<String>) -> Self {
        Self {
            ok: false,
            detail: detail.into(),
        }
    }
}

pub fn doctor_report() -> DoctorReport {
    hydrate_session_bus_env();

    let platform = platform_report();
    let portals = portal_report();
    let accessibility = accessibility_report();
    let input = input_report();
    let readiness = readiness_report(&accessibility, &input);

    DoctorReport {
        platform,
        portals,
        accessibility,
        input,
        readiness,
    }
}

pub fn hydrate_session_bus_env() {
    if env_var("XDG_RUNTIME_DIR").is_none() {
        if let Some(runtime) = xdg_runtime_dir() {
            if runtime.exists() {
                env::set_var("XDG_RUNTIME_DIR", runtime);
            }
        }
    }

    if env_var("DBUS_SESSION_BUS_ADDRESS").is_none() {
        if let Some(runtime) = xdg_runtime_dir() {
            let bus = runtime.join("bus");
            if bus.exists() {
                env::set_var(
                    "DBUS_SESSION_BUS_ADDRESS",
                    format!("unix:path={}", bus.display()),
                );
            }
        }
    }
}

pub fn setup_accessibility_report() -> SetupReport {
    hydrate_session_bus_env();

    let before = doctor_report();
    let accessibility_command = if can_build_accessibility_tree(&before.accessibility) {
        Check::ok("GNOME accessibility is already enabled")
    } else {
        command_check_with_session_bus(
            "gsettings",
            &[
                "set",
                "org.gnome.desktop.interface",
                "toolkit-accessibility",
                "true",
            ],
        )
    };
    let after = doctor_report();
    let before_ready = before.readiness.can_build_accessibility_tree;
    let after_ready = after.readiness.can_build_accessibility_tree;
    let changed_accessibility = !before_ready && after_ready;
    let requires_target_app_restart = changed_accessibility;
    let message = if after_ready {
        if changed_accessibility {
            "GNOME accessibility is enabled. Restart already-running target apps if their AT-SPI tree is still empty."
        } else {
            "GNOME accessibility is ready."
        }
    } else {
        "Could not enable GNOME accessibility automatically. Check the accessibility_command detail and enable org.gnome.desktop.interface toolkit-accessibility manually."
    }
    .to_string();

    SetupReport {
        before,
        accessibility_command,
        after,
        changed_accessibility,
        requires_target_app_restart,
        message,
    }
}

fn platform_report() -> PlatformReport {
    PlatformReport {
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        desktop_session: env_var("DESKTOP_SESSION"),
        xdg_session_type: env_var("XDG_SESSION_TYPE"),
        xdg_current_desktop: env_var("XDG_CURRENT_DESKTOP"),
        wayland_display: env_var("WAYLAND_DISPLAY"),
        display: env_var("DISPLAY"),
        dbus_session_bus_address: dbus_session_address(),
        xdg_runtime_dir: xdg_runtime_dir().map(|path| path.display().to_string()),
        gnome_shell_version: command_check("gnome-shell", &["--version"]),
    }
}

fn portal_report() -> PortalReport {
    PortalReport {
        desktop_portal: bus_name_check("org.freedesktop.portal.Desktop"),
        remote_desktop: portal_interface_check("org.freedesktop.portal.RemoteDesktop"),
        screencast: portal_interface_check("org.freedesktop.portal.ScreenCast"),
        screenshot: portal_interface_check("org.freedesktop.portal.Screenshot"),
        input_capture: portal_interface_check("org.freedesktop.portal.InputCapture"),
        mutter_remote_desktop: bus_name_check("org.gnome.Mutter.RemoteDesktop"),
        mutter_screencast: bus_name_check("org.gnome.Mutter.ScreenCast"),
    }
}

fn accessibility_report() -> AccessibilityReport {
    AccessibilityReport {
        at_spi_bus: gdbus_call_check(
            "org.a11y.Bus",
            "/org/a11y/bus",
            "org.a11y.Bus.GetAddress",
            &[],
        ),
        toolkit_accessibility: command_check_with_session_bus(
            "gsettings",
            &[
                "get",
                "org.gnome.desktop.interface",
                "toolkit-accessibility",
            ],
        ),
        at_spi_enabled: gdbus_call_check(
            "org.a11y.Bus",
            "/org/a11y/bus",
            "org.freedesktop.DBus.Properties.Get",
            &["org.a11y.Status", "IsEnabled"],
        ),
        screen_reader_enabled: gdbus_call_check(
            "org.a11y.Bus",
            "/org/a11y/bus",
            "org.freedesktop.DBus.Properties.Get",
            &["org.a11y.Status", "ScreenReaderEnabled"],
        ),
    }
}

fn input_report() -> InputReport {
    let socket = ydotool_socket_path();
    InputReport {
        ydotool: command_path_check("ydotool"),
        ydotoold: process_check("ydotoold"),
        ydotool_socket: path_check(&socket),
        uinput: path_check(Path::new("/dev/uinput")),
    }
}

fn readiness_report(accessibility: &AccessibilityReport, input: &InputReport) -> ReadinessReport {
    let mut blockers = Vec::new();
    let can_build_accessibility_tree = can_build_accessibility_tree(accessibility);
    let can_send_development_input =
        input.ydotool.ok && input.ydotoold.ok && input.ydotool_socket.ok && input.uinput.ok;

    if !can_build_accessibility_tree {
        blockers.push(
            "GNOME accessibility is disabled; enable org.gnome.desktop.interface toolkit-accessibility for AT-SPI tree extraction."
                .to_string(),
        );
    }

    if !can_send_development_input {
        blockers.push(
            "Development input fallback is not fully available; ydotool, ydotoold, socket, and /dev/uinput are required."
                .to_string(),
        );
    }

    let recommended_next_step = if !can_build_accessibility_tree {
        "Run setup_accessibility to enable GNOME accessibility before element-aware actions."
            .to_string()
    } else if !can_send_development_input {
        "Install and start ydotoold if development input fallback is needed.".to_string()
    } else {
        "Implement native AT-SPI action/value support for element-specific operations.".to_string()
    };

    ReadinessReport {
        can_register_mcp_tools: true,
        can_build_accessibility_tree,
        can_send_development_input,
        recommended_next_step,
        blockers,
    }
}

fn can_build_accessibility_tree(accessibility: &AccessibilityReport) -> bool {
    check_detail_contains_true(&accessibility.at_spi_enabled)
        || check_detail_contains_true(&accessibility.toolkit_accessibility)
}

fn check_detail_contains_true(check: &Check) -> bool {
    check.ok && check.detail.to_ascii_lowercase().contains("true")
}

fn env_var(key: &str) -> Option<String> {
    env::var(key).ok().filter(|value| !value.trim().is_empty())
}

fn xdg_runtime_dir() -> Option<PathBuf> {
    if let Some(value) = env_var("XDG_RUNTIME_DIR") {
        return Some(PathBuf::from(value));
    }
    user_id().map(|uid| PathBuf::from(format!("/run/user/{uid}")))
}

fn dbus_session_address() -> Option<String> {
    if let Some(value) = env_var("DBUS_SESSION_BUS_ADDRESS") {
        return Some(value);
    }
    xdg_runtime_dir()
        .map(|runtime| format!("unix:path={}", runtime.join("bus").display()))
        .filter(|address| {
            address
                .strip_prefix("unix:path=")
                .is_some_and(|p| Path::new(p).exists())
        })
}

fn ydotool_socket_path() -> PathBuf {
    if let Some(value) = env_var("YDOTOOL_SOCKET") {
        return PathBuf::from(value);
    }
    if let Some(runtime) = xdg_runtime_dir() {
        return runtime.join(".ydotool_socket");
    }
    PathBuf::from("/tmp/.ydotool_socket")
}

fn user_id() -> Option<String> {
    let output = Command::new("id").arg("-u").output().ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .filter(|value| !value.is_empty())
}

fn command_path_check(command: &str) -> Check {
    command_check("sh", &["-c", &format!("command -v {command}")])
}

fn process_check(process_name: &str) -> Check {
    command_check("pgrep", &["-a", process_name])
}

fn path_check(path: &Path) -> Check {
    if path.exists() {
        Check::ok(path.display().to_string())
    } else {
        Check::fail(format!("missing: {}", path.display()))
    }
}

fn bus_name_check(name: &str) -> Check {
    command_check_with_session_bus("busctl", &["--user", "status", name])
}

fn portal_interface_check(interface: &str) -> Check {
    command_check_with_session_bus(
        "busctl",
        &[
            "--user",
            "introspect",
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            interface,
        ],
    )
}

fn gdbus_call_check(destination: &str, object_path: &str, method: &str, args: &[&str]) -> Check {
    let mut command_args = vec![
        "call",
        "--session",
        "--dest",
        destination,
        "--object-path",
        object_path,
        "--method",
        method,
    ];
    command_args.extend_from_slice(args);
    command_check_with_session_bus("gdbus", &command_args)
}

fn command_check(command: &str, args: &[&str]) -> Check {
    run_command(command, args, false)
}

fn command_check_with_session_bus(command: &str, args: &[&str]) -> Check {
    run_command(command, args, true)
}

fn run_command(command: &str, args: &[&str], with_session_bus: bool) -> Check {
    let mut cmd = Command::new(command);
    cmd.args(args);

    if with_session_bus {
        if let Some(address) = dbus_session_address() {
            cmd.env("DBUS_SESSION_BUS_ADDRESS", address);
        }
        if let Some(runtime) = xdg_runtime_dir() {
            cmd.env("XDG_RUNTIME_DIR", runtime);
        }
    }

    match cmd.output() {
        Ok(output) if output.status.success() => {
            let detail = String::from_utf8_lossy(&output.stdout).trim().to_string();
            Check::ok(if detail.is_empty() {
                "ok".into()
            } else {
                detail
            })
        }
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
            let detail = if !stderr.is_empty() { stderr } else { stdout };
            Check::fail(if detail.is_empty() {
                format!("exit status {}", output.status)
            } else {
                detail
            })
        }
        Err(error) => Check::fail(error.to_string()),
    }
}
