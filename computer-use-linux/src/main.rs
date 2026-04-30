mod atspi_tree;
mod diagnostics;
mod screenshot;
mod server;

use anyhow::{Context, Result};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    diagnostics::hydrate_session_bus_env();

    match std::env::args().nth(1).as_deref() {
        Some("mcp") => server::serve_mcp().await,
        Some("doctor") => {
            let report = diagnostics::doctor_report();
            println!(
                "{}",
                serde_json::to_string_pretty(&report)
                    .context("failed to serialize doctor report")?
            );
            Ok(())
        }
        Some("setup") => {
            let report = diagnostics::setup_accessibility_report();
            println!(
                "{}",
                serde_json::to_string_pretty(&report)
                    .context("failed to serialize setup report")?
            );
            Ok(())
        }
        Some("apps") => {
            let apps = atspi_tree::list_accessible_apps(50).await?;
            println!(
                "{}",
                serde_json::to_string_pretty(&apps)
                    .context("failed to serialize accessible apps")?
            );
            Ok(())
        }
        Some("state") => {
            let app_name_or_bundle_identifier = std::env::args().nth(2);
            let nodes =
                atspi_tree::snapshot_tree(app_name_or_bundle_identifier.as_deref(), 120, 12)
                    .await?;
            println!(
                "{}",
                serde_json::to_string_pretty(&nodes)
                    .context("failed to serialize accessibility tree")?
            );
            Ok(())
        }
        Some("screenshot") => {
            let capture = screenshot::capture_screenshot().await?;
            println!(
                "{}",
                serde_json::to_string_pretty(&serde_json::json!({
                    "mime_type": capture.mime_type,
                    "source": capture.source,
                    "data_url_length": capture.data_url.len()
                }))
                .context("failed to serialize screenshot report")?
            );
            Ok(())
        }
        Some("--help") | Some("-h") => {
            print_help();
            Ok(())
        }
        Some(command) => {
            anyhow::bail!(
                "unknown command '{command}'. Expected one of: mcp, doctor, setup, apps, state, screenshot"
            );
        }
        None => {
            print_help();
            Ok(())
        }
    }
}

fn print_help() {
    println!(
        "codex-computer-use-linux\n\nUsage:\n  codex-computer-use-linux mcp\n  codex-computer-use-linux doctor\n  codex-computer-use-linux setup\n  codex-computer-use-linux apps\n  codex-computer-use-linux state [APP_NAME]\n  codex-computer-use-linux screenshot"
    );
}
