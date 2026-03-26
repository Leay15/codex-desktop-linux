use crate::{
    config::{RuntimeConfig, RuntimePaths},
    install::PackageKind,
    state::{ArtifactPaths, PersistedState, UpdateStatus},
};
use anyhow::{Context, Result};
use std::{
    ffi::OsString,
    fs,
    path::{Path, PathBuf},
};
use tokio::process::Command;
use tracing::info;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuildArtifacts {
    pub workspace_dir: PathBuf,
    pub package_path: PathBuf,
}

pub async fn build_update(
    config: &RuntimeConfig,
    state: &mut PersistedState,
    paths: &RuntimePaths,
    candidate_version: &str,
    dmg_path: &Path,
) -> Result<BuildArtifacts> {
    let workspace_dir = config.workspace_root.join("workspaces").join(candidate_version);
    let bundle_dir = workspace_dir.join("builder");
    let dist_dir = workspace_dir.join("dist");
    let app_dir = workspace_dir.join("codex-app");
    let logs_dir = workspace_dir.join("logs");
    let install_log = logs_dir.join("install.log");
    let build_log = logs_dir.join("build-package.log");

    if workspace_dir.exists() {
        fs::remove_dir_all(&workspace_dir)
            .with_context(|| format!("Failed to remove {}", workspace_dir.display()))?;
    }

    fs::create_dir_all(&logs_dir)
        .with_context(|| format!("Failed to create {}", logs_dir.display()))?;

    let build_path = build_command_path();

    state.status = UpdateStatus::PreparingWorkspace;
    state.artifact_paths.workspace_dir = Some(workspace_dir.clone());
    state.save(&paths.state_file)?;

    copy_builder_bundle(&config.builder_bundle_root, &bundle_dir)?;

    state.status = UpdateStatus::PatchingApp;
    state.save(&paths.state_file)?;
    run_and_log(
        Command::new(bundle_dir.join("install.sh"))
            .arg(dmg_path)
            .env("CODEX_INSTALL_DIR", &app_dir)
            .env("PATH", &build_path)
            .current_dir(&bundle_dir),
        &install_log,
    )
    .await
    .context("install.sh failed during local rebuild")?;

    state.status = UpdateStatus::BuildingPackage;
    state.save(&paths.state_file)?;

    let build_script = package_build_script(&bundle_dir);
    run_and_log(
        Command::new(&build_script)
            .env("PACKAGE_VERSION", candidate_version)
            .env("APP_DIR_OVERRIDE", &app_dir)
            .env("DIST_DIR_OVERRIDE", &dist_dir)
            .env("UPDATER_BINARY_SOURCE", std::env::current_exe()?)
            .env(
                "UPDATER_SERVICE_SOURCE",
                bundle_dir.join("packaging/linux/codex-update-manager.service"),
            )
            .env("PATH", &build_path)
            .current_dir(&bundle_dir),
        &build_log,
    )
    .await
    .with_context(|| format!("{} failed during local rebuild", build_script.display()))?;

    let package_path = find_package_in(&dist_dir)?;
    state.status = UpdateStatus::ReadyToInstall;
    state.artifact_paths = ArtifactPaths {
        dmg_path: Some(dmg_path.to_path_buf()),
        workspace_dir: Some(workspace_dir.clone()),
        package_path: Some(package_path.clone()),
    };
    state.save(&paths.state_file)?;
    info!(candidate_version, package = %package_path.display(), "local update build ready");

    Ok(BuildArtifacts {
        workspace_dir,
        package_path,
    })
}

/// Returns the path to the native-package build script appropriate for the running system.
fn package_build_script(bundle_dir: &Path) -> PathBuf {
    match PackageKind::detect() {
        PackageKind::Rpm => bundle_dir.join("scripts/build-rpm.sh"),
        PackageKind::Deb => bundle_dir.join("scripts/build-deb.sh"),
    }
}

fn copy_builder_bundle(source_root: &Path, destination_root: &Path) -> Result<()> {
    copy_path(&source_root.join("install.sh"), &destination_root.join("install.sh"))?;
    copy_path(
        &source_root.join("scripts/build-deb.sh"),
        &destination_root.join("scripts/build-deb.sh"),
    )?;
    // RPM build script is optional; present when the bundle was built on (or
    // prepared for) a Fedora/RPM-based system.
    let rpm_script_src = source_root.join("scripts/build-rpm.sh");
    if rpm_script_src.exists() {
        copy_path(
            &rpm_script_src,
            &destination_root.join("scripts/build-rpm.sh"),
        )?;
    }
    copy_dir_recursive(
        &source_root.join("packaging/linux"),
        &destination_root.join("packaging/linux"),
    )?;
    copy_path(
        &source_root.join("assets/codex.png"),
        &destination_root.join("assets/codex.png"),
    )?;
    Ok(())
}

fn copy_path(source: &Path, destination: &Path) -> Result<()> {
    let parent = destination
        .parent()
        .context("Destination path has no parent directory")?;
    fs::create_dir_all(parent)
        .with_context(|| format!("Failed to create {}", parent.display()))?;
    fs::copy(source, destination)
        .with_context(|| format!("Failed to copy {} to {}", source.display(), destination.display()))?;
    let metadata = fs::metadata(source)
        .with_context(|| format!("Failed to stat {}", source.display()))?;
    fs::set_permissions(destination, metadata.permissions())
        .with_context(|| format!("Failed to set permissions on {}", destination.display()))?;
    Ok(())
}

fn copy_dir_recursive(source: &Path, destination: &Path) -> Result<()> {
    fs::create_dir_all(destination)
        .with_context(|| format!("Failed to create {}", destination.display()))?;

    for entry in fs::read_dir(source)
        .with_context(|| format!("Failed to read {}", source.display()))?
    {
        let entry = entry?;
        let entry_path = entry.path();
        let destination_path = destination.join(entry.file_name());

        if entry.file_type()?.is_dir() {
            copy_dir_recursive(&entry_path, &destination_path)?;
        } else {
            copy_path(&entry_path, &destination_path)?;
        }
    }

    Ok(())
}

/// Find a native package file (.deb or .rpm) inside `dist_dir`.
fn find_package_in(dist_dir: &Path) -> Result<PathBuf> {
    for entry in fs::read_dir(dist_dir)
        .with_context(|| format!("Failed to read {}", dist_dir.display()))?
    {
        let entry = entry?;
        let path = entry.path();
        if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            if ext == "deb" || ext == "rpm" {
                return Ok(path);
            }
        }
    }

    anyhow::bail!("No .deb or .rpm package found in {}", dist_dir.display())
}

fn build_command_path() -> OsString {
    let mut entries = preferred_node_bin_dirs();
    entries.extend(std::env::split_paths(
        &std::env::var_os("PATH").unwrap_or_default(),
    ));
    std::env::join_paths(entries).unwrap_or_else(|_| std::env::var_os("PATH").unwrap_or_default())
}

fn preferred_node_bin_dirs() -> Vec<PathBuf> {
    let nvm_root = std::env::var_os("NVM_DIR")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".nvm")));

    let Some(nvm_root) = nvm_root else {
        return Vec::new();
    };

    collect_nvm_bin_dirs(&nvm_root)
}

fn collect_nvm_bin_dirs(nvm_root: &Path) -> Vec<PathBuf> {
    let mut directories = Vec::new();
    let mut seen = std::collections::BTreeSet::new();

    let current_bin = nvm_root.join("versions/node/current/bin");
    if is_node_toolchain_dir(&current_bin) {
        seen.insert(current_bin.clone());
        directories.push(current_bin);
    }

    let versions_root = nvm_root.join("versions/node");
    if let Ok(entries) = fs::read_dir(&versions_root) {
        let mut version_bins = entries
            .filter_map(|entry| entry.ok().map(|item| item.path().join("bin")))
            .filter(|path| is_node_toolchain_dir(path))
            .collect::<Vec<_>>();
        version_bins.sort();
        version_bins.reverse();

        for path in version_bins {
            if seen.insert(path.clone()) {
                directories.push(path);
            }
        }
    }

    directories
}

fn is_node_toolchain_dir(path: &Path) -> bool {
    ["node", "npm", "npx"]
        .into_iter()
        .all(|binary| path.join(binary).is_file())
}

async fn run_and_log(command: &mut Command, log_path: &Path) -> Result<()> {
    let output = command
        .output()
        .await
        .context("Failed to spawn external command")?;

    let mut combined = Vec::new();
    combined.extend_from_slice(&output.stdout);
    combined.extend_from_slice(&output.stderr);
    fs::write(log_path, &combined)
        .with_context(|| format!("Failed to write {}", log_path.display()))?;

    if !output.status.success() {
        anyhow::bail!(
            "Command failed with status {:?}; see {}",
            output.status.code(),
            log_path.display()
        );
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::RuntimePaths;
    use anyhow::Result;
    use tempfile::tempdir;

    fn write_fake_build_script(path: &Path, deb_output: bool) -> Result<()> {
        let script_body = if deb_output {
            r#"#!/bin/bash
set -euo pipefail
mkdir -p "${DIST_DIR_OVERRIDE}"
touch "${DIST_DIR_OVERRIDE}/codex-desktop_${PACKAGE_VERSION}_amd64.deb"
"#
        } else {
            r#"#!/bin/bash
set -euo pipefail
mkdir -p "${DIST_DIR_OVERRIDE}"
touch "${DIST_DIR_OVERRIDE}/codex-desktop-${PACKAGE_VERSION}.x86_64.rpm"
"#
        };

        fs::write(path, script_body)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path, fs::Permissions::from_mode(0o755))?;
        }
        Ok(())
    }

    #[tokio::test]
    async fn builds_update_with_fake_bundle() -> Result<()> {
        let temp = tempdir()?;
        let bundle_root = temp.path().join("bundle");
        let state_root = temp.path().join("state");
        let cache_root = temp.path().join("cache");
        fs::create_dir_all(bundle_root.join("scripts"))?;
        fs::create_dir_all(bundle_root.join("packaging/linux"))?;
        fs::create_dir_all(bundle_root.join("assets"))?;
        fs::write(bundle_root.join("assets/codex.png"), b"png")?;
        fs::write(bundle_root.join("packaging/linux/control"), "Package: codex")?;
        fs::write(
            bundle_root.join("packaging/linux/codex-desktop.spec"),
            "Name: codex",
        )?;
        fs::write(
            bundle_root.join("packaging/linux/codex-desktop.desktop"),
            "[Desktop Entry]",
        )?;
        fs::write(
            bundle_root.join("packaging/linux/codex-update-manager.service"),
            "[Unit]\nDescription=Codex Update Manager\n",
        )?;
        fs::write(
            bundle_root.join("install.sh"),
            r#"#!/bin/bash
set -euo pipefail
mkdir -p "${CODEX_INSTALL_DIR}"
echo launcher > "${CODEX_INSTALL_DIR}/start.sh"
chmod +x "${CODEX_INSTALL_DIR}/start.sh"
"#,
        )?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(
                bundle_root.join("install.sh"),
                fs::Permissions::from_mode(0o755),
            )?;
        }

        // Provide both build scripts so the test works on both Debian and Fedora.
        write_fake_build_script(&bundle_root.join("scripts/build-deb.sh"), true)?;
        write_fake_build_script(&bundle_root.join("scripts/build-rpm.sh"), false)?;

        let paths = RuntimePaths {
            config_file: temp.path().join("config/config.toml"),
            state_file: state_root.join("state.json"),
            log_file: state_root.join("service.log"),
            cache_dir: cache_root.clone(),
            state_dir: state_root.clone(),
            config_dir: temp.path().join("config"),
        };
        paths.ensure_dirs()?;

        let config = RuntimeConfig {
            dmg_url: "https://example.com/Codex.dmg".to_string(),
            initial_check_delay_seconds: 30,
            check_interval_hours: 6,
            auto_install_on_app_exit: true,
            notifications: true,
            workspace_root: cache_root,
            builder_bundle_root: bundle_root,
            app_executable_path: PathBuf::from("/opt/codex-desktop/electron"),
        };
        let dmg_path = temp.path().join("Codex.dmg");
        fs::write(&dmg_path, b"dmg")?;

        let mut state = PersistedState::new(true);
        let artifacts =
            build_update(&config, &mut state, &paths, "2026.03.24+abcd1234", &dmg_path).await?;
        assert_eq!(state.status, UpdateStatus::ReadyToInstall);
        assert!(artifacts.workspace_dir.exists());
        assert!(artifacts.package_path.exists());
        // The file should be either a .deb or .rpm depending on the host distro.
        let ext = artifacts
            .package_path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("");
        assert!(
            ext == "deb" || ext == "rpm",
            "expected .deb or .rpm, got .{ext}"
        );
        Ok(())
    }

    #[test]
    fn collects_nvm_toolchain_bins_with_current_first() -> Result<()> {
        let temp = tempdir()?;
        let nvm_root = temp.path().join(".nvm");
        let current_bin = nvm_root.join("versions/node/current/bin");
        let version_bin = nvm_root.join("versions/node/v24.2.0/bin");

        fs::create_dir_all(&current_bin)?;
        fs::create_dir_all(&version_bin)?;
        for dir in [&current_bin, &version_bin] {
            for binary in ["node", "npm", "npx"] {
                fs::write(dir.join(binary), b"bin")?;
            }
        }

        let directories = collect_nvm_bin_dirs(&nvm_root);
        assert_eq!(directories.first(), Some(&current_bin));
        assert!(directories.contains(&version_bin));
        Ok(())
    }
}
