use anyhow::Result;

pub fn send(summary: &str, body: &str) -> Result<()> {
    notify_rust::Notification::new()
        .summary(summary)
        .body(body)
        .appname("Codex Update Manager")
        .show()?;
    Ok(())
}
