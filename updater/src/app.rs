use crate::{
    builder,
    cli::{Cli, Commands},
    config::{RuntimeConfig, RuntimePaths},
    install, liveness, logging, notify,
    state::{PersistedState, UpdateStatus},
    upstream,
};
use anyhow::{Context, Result};
use chrono::Utc;
use reqwest::Client;
use std::path::Path;
use tokio::time::{self, Duration};
use tracing::{error, info, warn};

const RECONCILE_INTERVAL_SECONDS: u64 = 15;

pub async fn run(cli: Cli) -> Result<()> {
    let paths = RuntimePaths::detect()?;
    paths.ensure_dirs()?;
    logging::init(&paths.log_file)?;

    let config = RuntimeConfig::load_or_default(&paths)?;
    let mut state =
        PersistedState::load_or_default(&paths.state_file, config.auto_install_on_app_exit)?;
    state.installed_version = install::installed_package_version();
    state.save(&paths.state_file)?;

    match cli.command {
        Commands::Daemon => run_daemon(&config, &mut state, &paths).await,
        Commands::CheckNow => run_check_now(&config, &mut state, &paths).await,
        Commands::Status { json } => run_status(state, json),
        Commands::InstallDeb { path } => install::install_deb(&path),
        Commands::InstallRpm { path } => install::install_rpm(&path),
    }
}

async fn run_daemon(
    config: &RuntimeConfig,
    state: &mut PersistedState,
    paths: &RuntimePaths,
) -> Result<()> {
    state.auto_install_on_app_exit = config.auto_install_on_app_exit;
    state.save(&paths.state_file)?;
    info!("daemon initialized");

    time::sleep(Duration::from_secs(config.initial_check_delay_seconds)).await;
    if let Err(error) = run_check_cycle(config, state, paths).await {
        error!(?error, "initial check failed");
    }
    if let Err(error) = reconcile_pending_install(config, state, paths).await {
        error!(?error, "initial reconciliation failed");
    }

    let mut check_interval = time::interval(Duration::from_secs(config.check_interval_hours * 3600));
    let mut reconcile_interval = time::interval(Duration::from_secs(RECONCILE_INTERVAL_SECONDS));
    check_interval.tick().await;
    reconcile_interval.tick().await;
    loop {
        tokio::select! {
            _ = check_interval.tick() => {
                if let Err(error) = run_check_cycle(config, state, paths).await {
                    error!(?error, "periodic check failed");
                }
            }
            _ = reconcile_interval.tick() => {
                if let Err(error) = reconcile_pending_install(config, state, paths).await {
                    error!(?error, "pending install reconciliation failed");
                }
            }
            signal = tokio::signal::ctrl_c() => {
                signal?;
                info!("daemon received shutdown signal");
                break;
            }
        }
    }

    Ok(())
}

async fn run_check_now(
    config: &RuntimeConfig,
    state: &mut PersistedState,
    paths: &RuntimePaths,
) -> Result<()> {
    state.auto_install_on_app_exit = config.auto_install_on_app_exit;
    state.save(&paths.state_file)?;
    run_check_cycle(config, state, paths).await?;
    reconcile_pending_install(config, state, paths).await
}

fn run_status(state: PersistedState, json: bool) -> Result<()> {
    if json {
        println!("{}", serde_json::to_string_pretty(&state)?);
    } else {
        println!("status: {:?}", state.status);
        println!("installed_version: {}", state.installed_version);
        println!(
            "candidate_version: {}",
            state.candidate_version.as_deref().unwrap_or("none")
        );
    }

    Ok(())
}

async fn run_check_cycle(
    config: &RuntimeConfig,
    state: &mut PersistedState,
    paths: &RuntimePaths,
) -> Result<()> {
    let retrying_failed_update = state.status == UpdateStatus::Failed;

    if matches!(
        state.status,
        UpdateStatus::ReadyToInstall | UpdateStatus::WaitingForAppExit | UpdateStatus::Installing
    ) {
        info!("skipping upstream check because an update is already pending");
        return Ok(());
    }

    let client = Client::builder().build()?;

    state.auto_install_on_app_exit = config.auto_install_on_app_exit;
    state.installed_version = install::installed_package_version();
    state.status = UpdateStatus::CheckingUpstream;
    state.last_check_at = Some(Utc::now());
    state.error_message = None;
    state.save(&paths.state_file)?;

    let result: Result<()> = async {
        let metadata = upstream::fetch_remote_metadata(&client, &config.dmg_url).await?;
        let previous_headers_fingerprint = state.remote_headers_fingerprint.clone();
        state.remote_headers_fingerprint = Some(metadata.headers_fingerprint.clone());
        state.last_successful_check_at = Some(Utc::now());

        if previous_headers_fingerprint.as_deref() == Some(metadata.headers_fingerprint.as_str())
            && state.dmg_sha256.is_some()
            && !retrying_failed_update
        {
            state.status = UpdateStatus::Idle;
            state.save(&paths.state_file)?;
            info!("upstream fingerprint unchanged; skipping download");
            return Ok(());
        }

        state.status = UpdateStatus::DownloadingDmg;
        state.save(&paths.state_file)?;

        let downloads_dir = config.workspace_root.join("downloads");
        let downloaded =
            upstream::download_dmg(&client, &config.dmg_url, &downloads_dir, Utc::now()).await?;

        if state.dmg_sha256.as_deref() == Some(downloaded.sha256.as_str()) && !retrying_failed_update {
            state.status = UpdateStatus::Idle;
            state.artifact_paths.dmg_path = Some(downloaded.path);
            state.save(&paths.state_file)?;
            info!("downloaded DMG hash matches current cached DMG; no update detected");
            return Ok(());
        }

        state.status = UpdateStatus::UpdateDetected;
        state.candidate_version = Some(downloaded.candidate_version);
        state.dmg_sha256 = Some(downloaded.sha256);
        state.artifact_paths.dmg_path = Some(downloaded.path.clone());
        state.notified_events.clear();
        state.save(&paths.state_file)?;

        maybe_notify(
            state,
            paths,
            config.notifications,
            "update_detected",
            "New Codex Desktop update detected",
            "Preparing a local Linux package from the new upstream DMG.",
        )?;

        let candidate_version = state
            .candidate_version
            .clone()
            .expect("candidate version should be set before local build");
        builder::build_update(config, state, paths, &candidate_version, &downloaded.path).await?;
        maybe_notify(
            state,
            paths,
            config.notifications,
            "ready_to_install",
            "Codex Desktop update ready",
            "A rebuilt Linux package is ready to install.",
        )?;
        Ok(())
    }
    .await;

    if let Err(error) = result {
        state.mark_failed(error.to_string());
        state.save(&paths.state_file)?;
        let _ = notify_failure(config, state, paths, &error);
        return Err(error);
    }

    Ok(())
}

async fn reconcile_pending_install(
    config: &RuntimeConfig,
    state: &mut PersistedState,
    paths: &RuntimePaths,
) -> Result<()> {
    state.installed_version = install::installed_package_version();
    state.auto_install_on_app_exit = config.auto_install_on_app_exit;

    if state.status == UpdateStatus::Failed
        && state.candidate_version.is_some()
        && state
            .artifact_paths
            .package_path
            .as_ref()
            .is_some_and(|path| path.exists())
    {
        state.status = UpdateStatus::ReadyToInstall;
        state.error_message = None;
        state.save(&paths.state_file)?;
    }

    match state.status {
        UpdateStatus::ReadyToInstall | UpdateStatus::WaitingForAppExit => {
            let Some(package_path) = state.artifact_paths.package_path.clone() else {
                return Ok(());
            };

            if !package_path.exists() {
                state.mark_failed(format!("Pending package artifact is missing: {}", package_path.display()));
                state.save(&paths.state_file)?;
                return Ok(());
            }

            if liveness::is_app_running(config)? {
                state.status = UpdateStatus::WaitingForAppExit;
                state.save(&paths.state_file)?;
                maybe_notify(
                    state,
                    paths,
                    config.notifications,
                    "waiting_for_app_exit",
                    "Codex Desktop update ready",
                    "An update is ready and will install after you close Codex Desktop.",
                )?;
                return Ok(());
            }

            if !state.auto_install_on_app_exit {
                state.status = UpdateStatus::ReadyToInstall;
                state.save(&paths.state_file)?;
                return Ok(());
            }

            trigger_install(state, paths, &package_path).await?;
        }
        _ => {}
    }

    Ok(())
}

fn maybe_notify(
    state: &mut PersistedState,
    paths: &RuntimePaths,
    enabled: bool,
    event_name: &str,
    summary: &str,
    body: &str,
) -> Result<()> {
    let version = state
        .candidate_version
        .as_deref()
        .unwrap_or(&state.installed_version);
    let event_key = format!("{event_name}:{version}");
    if !state.notified_events.insert(event_key) {
        return Ok(());
    }

    if enabled {
        if let Err(error) = notify::send(summary, body) {
            warn!(?error, "failed to send desktop notification");
        }
    }

    state.save(&paths.state_file)?;
    Ok(())
}

async fn trigger_install(
    state: &mut PersistedState,
    paths: &RuntimePaths,
    package_path: &Path,
) -> Result<()> {
    state.status = UpdateStatus::Installing;
    state.error_message = None;
    state.save(&paths.state_file)?;

    let _ = notify::send(
        "Installing Codex Desktop update",
        "Applying the locally rebuilt Linux package.",
    );

    let current_exe = std::env::current_exe().context("Failed to resolve updater binary path")?;
    let status = install::pkexec_command(&current_exe, package_path)
        .status()
        .context("Failed to launch pkexec for update installation")?;

    if status.success() {
        state.status = UpdateStatus::Installed;
        state.installed_version = install::installed_package_version();
        state.candidate_version = None;
        state.error_message = None;
        state.notified_events.clear();
        state.save(&paths.state_file)?;
        let _ = notify::send(
            "Codex Desktop updated",
            "The new package is installed and will be used the next time you open the app.",
        );
        return Ok(());
    }

    let error = anyhow::anyhow!("Privileged install exited with status {status}");
    state.mark_failed(error.to_string());
    state.save(&paths.state_file)?;
    let _ = notify::send(
        "Codex update failed",
        "The package could not be installed. Check the updater log for details.",
    );
    Err(error)
}

fn notify_failure(
    config: &RuntimeConfig,
    state: &mut PersistedState,
    paths: &RuntimePaths,
    error: &anyhow::Error,
) -> Result<()> {
    let body = format!("The local rebuild failed: {error}");
    maybe_notify(
        state,
        paths,
        config.notifications,
        "build_failed",
        "Codex update failed",
        &body,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn failed_state_with_existing_deb_returns_to_ready_to_install() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let paths = RuntimePaths {
            config_file: temp.path().join("config/config.toml"),
            state_file: temp.path().join("state/state.json"),
            log_file: temp.path().join("state/service.log"),
            cache_dir: temp.path().join("cache"),
            state_dir: temp.path().join("state"),
            config_dir: temp.path().join("config"),
        };
        paths.ensure_dirs()?;

        let package_path = temp.path().join("dist/codex.deb");
        std::fs::create_dir_all(package_path.parent().expect("package path should have parent"))?;
        std::fs::write(&package_path, b"deb")?;

        let config = RuntimeConfig {
            dmg_url: "https://example.com/Codex.dmg".to_string(),
            initial_check_delay_seconds: 1,
            check_interval_hours: 6,
            auto_install_on_app_exit: false,
            notifications: false,
            workspace_root: temp.path().join("cache"),
            builder_bundle_root: temp.path().join("builder"),
            app_executable_path: temp.path().join("not-running-electron"),
        };

        let mut state = PersistedState::new(false);
        state.status = UpdateStatus::Failed;
        state.candidate_version = Some("2026.03.25.010203+deadbeef".to_string());
        state.error_message = Some("previous failure".to_string());
        state.artifact_paths.package_path = Some(package_path);

        reconcile_pending_install(&config, &mut state, &paths).await?;

        assert_eq!(state.status, UpdateStatus::ReadyToInstall);
        assert_eq!(state.error_message, None);
        Ok(())
    }

    #[test]
    fn notification_events_are_deduplicated() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let paths = RuntimePaths {
            config_file: temp.path().join("config/config.toml"),
            state_file: temp.path().join("state/state.json"),
            log_file: temp.path().join("state/service.log"),
            cache_dir: temp.path().join("cache"),
            state_dir: temp.path().join("state"),
            config_dir: temp.path().join("config"),
        };
        paths.ensure_dirs()?;

        let mut state = PersistedState::new(true);
        state.candidate_version = Some("2026.03.24+abcd1234".to_string());
        maybe_notify(
            &mut state,
            &paths,
            false,
            "ready_to_install",
            "Codex Desktop update ready",
            "An update is ready to install.",
        )?;
        let notified_count = state.notified_events.len();
        maybe_notify(
            &mut state,
            &paths,
            false,
            "ready_to_install",
            "Codex Desktop update ready",
            "An update is ready to install.",
        )?;

        assert_eq!(state.notified_events.len(), notified_count);
        Ok(())
    }
}
