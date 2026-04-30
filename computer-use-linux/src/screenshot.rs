use crate::diagnostics::hydrate_session_bus_env;
use anyhow::{anyhow, bail, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use futures_util::StreamExt;
use schemars::JsonSchema;
use serde::Serialize;
use std::{
    collections::HashMap,
    fs,
    path::PathBuf,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use zbus::{
    zvariant::{OwnedObjectPath, OwnedValue, Value},
    Proxy,
};

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct ScreenshotCapture {
    pub mime_type: String,
    pub data_url: String,
    pub source: String,
}

pub async fn capture_screenshot() -> Result<ScreenshotCapture> {
    hydrate_session_bus_env();

    match capture_with_gnome_shell().await {
        Ok(capture) => Ok(capture),
        Err(gnome_error) => match capture_with_portal().await {
            Ok(capture) => Ok(capture),
            Err(portal_error) => Err(anyhow!(
                "GNOME Shell screenshot failed: {gnome_error}; XDG portal screenshot failed: {portal_error}"
            )),
        },
    }
}

async fn capture_with_gnome_shell() -> Result<ScreenshotCapture> {
    let connection = zbus::Connection::session()
        .await
        .context("failed to connect to session bus")?;
    let proxy = Proxy::new(
        &connection,
        "org.gnome.Shell.Screenshot",
        "/org/gnome/Shell/Screenshot",
        "org.gnome.Shell.Screenshot",
    )
    .await
    .context("failed to create GNOME Shell screenshot proxy")?;
    let path = temp_png_path("gnome-shell");
    let filename = path
        .to_str()
        .context("temporary screenshot path is not valid UTF-8")?;
    let (success, filename_used): (bool, String) = proxy
        .call("Screenshot", &(false, false, filename))
        .await
        .context("GNOME Shell Screenshot call failed")?;

    if !success {
        bail!("GNOME Shell reported screenshot failure");
    }

    read_png_as_capture(PathBuf::from(filename_used), "gnome-shell").await
}

async fn capture_with_portal() -> Result<ScreenshotCapture> {
    let connection = zbus::Connection::session()
        .await
        .context("failed to connect to session bus")?;
    let unique_name = connection
        .unique_name()
        .context("session bus connection has no unique name")?;
    let token = request_token();
    let request_path = format!(
        "/org/freedesktop/portal/desktop/request/{}/{}",
        unique_name
            .as_str()
            .trim_start_matches(':')
            .replace('.', "_"),
        token
    );
    let request_proxy = Proxy::new(
        &connection,
        "org.freedesktop.portal.Desktop",
        request_path.as_str(),
        "org.freedesktop.portal.Request",
    )
    .await
    .context("failed to create XDG portal request proxy")?;
    let mut response_stream = request_proxy
        .receive_signal("Response")
        .await
        .context("failed to subscribe to XDG portal screenshot response")?;

    let portal_proxy = Proxy::new(
        &connection,
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Screenshot",
    )
    .await
    .context("failed to create XDG portal screenshot proxy")?;
    let mut options: HashMap<&str, Value<'_>> = HashMap::new();
    options.insert("handle_token", Value::from(token.as_str()));
    options.insert("interactive", Value::from(false));
    let handle: OwnedObjectPath = portal_proxy
        .call("Screenshot", &("", options))
        .await
        .context("XDG portal Screenshot call failed")?;

    if handle.as_str() != request_path {
        response_stream = Proxy::new(
            &connection,
            "org.freedesktop.portal.Desktop",
            handle.as_str(),
            "org.freedesktop.portal.Request",
        )
        .await
        .context("failed to create returned XDG portal request proxy")?
        .receive_signal("Response")
        .await
        .context("failed to subscribe to returned XDG portal screenshot response")?;
    }

    let response = tokio::time::timeout(Duration::from_secs(20), response_stream.next())
        .await
        .context("timed out waiting for XDG portal screenshot response")?
        .context("XDG portal screenshot response stream ended")?;
    let (response_code, results): (u32, HashMap<String, OwnedValue>) = response
        .body()
        .deserialize()
        .context("failed to decode XDG portal screenshot response")?;

    if response_code != 0 {
        bail!("XDG portal screenshot was denied or cancelled with response code {response_code}");
    }

    let uri_value = results
        .get("uri")
        .context("XDG portal screenshot response did not include a uri")?;
    let uri: String = uri_value
        .try_clone()
        .context("failed to clone XDG portal screenshot uri")?
        .try_into()
        .context("XDG portal screenshot uri was not a string")?;
    let path = file_uri_to_path(&uri)?;

    read_png_as_capture(path, "xdg-desktop-portal").await
}

async fn read_png_as_capture(path: PathBuf, source: &str) -> Result<ScreenshotCapture> {
    let bytes = fs::read(&path)
        .with_context(|| format!("failed to read screenshot file {}", path.display()))?;
    if bytes.is_empty() {
        bail!("screenshot file was empty: {}", path.display());
    }
    let encoded = STANDARD.encode(bytes);
    let _ = fs::remove_file(path);
    Ok(ScreenshotCapture {
        mime_type: "image/png".to_string(),
        data_url: format!("data:image/png;base64,{encoded}"),
        source: source.to_string(),
    })
}

fn file_uri_to_path(uri: &str) -> Result<PathBuf> {
    let Some(rest) = uri.strip_prefix("file://") else {
        bail!("unsupported screenshot uri: {uri}");
    };
    Ok(PathBuf::from(percent_decode(rest)))
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;

    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let Ok(hex) = std::str::from_utf8(&bytes[index + 1..index + 3]) {
                if let Ok(byte) = u8::from_str_radix(hex, 16) {
                    decoded.push(byte);
                    index += 3;
                    continue;
                }
            }
        }

        decoded.push(bytes[index]);
        index += 1;
    }

    String::from_utf8_lossy(&decoded).into_owned()
}

fn temp_png_path(source: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "codex-computer-use-{source}-{}.png",
        unique_suffix()
    ))
}

fn request_token() -> String {
    format!("codex_{}", unique_suffix().replace('-', "_"))
}

fn unique_suffix() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    format!("{}-{nanos}", std::process::id())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_file_uri_percent_escapes() {
        assert_eq!(
            file_uri_to_path("file:///tmp/Codex%20Screenshot.png").unwrap(),
            PathBuf::from("/tmp/Codex Screenshot.png")
        );
    }

    #[test]
    fn request_token_is_portal_safe() {
        let token = request_token();
        assert!(token.starts_with("codex_"));
        assert!(token.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'));
    }
}
