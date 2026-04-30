use crate::diagnostics::hydrate_session_bus_env;
use anyhow::{Context, Result};
use atspi::{
    connection::P2P,
    proxy::{accessible::AccessibleProxy, proxy_ext::ProxyExt},
    AccessibilityConnection, CoordType, ObjectRefOwned,
};
use schemars::JsonSchema;
use serde::Serialize;
use std::collections::VecDeque;

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct AccessibleAppSummary {
    pub object_ref: String,
    pub name: Option<String>,
    pub role: String,
    pub child_count: i32,
    pub bounds: Option<Bounds>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct AccessibilityNode {
    pub index: u32,
    pub parent_index: Option<u32>,
    pub depth: u32,
    pub object_ref: String,
    pub role: String,
    pub name: Option<String>,
    pub description: Option<String>,
    pub child_count: i32,
    pub bounds: Option<Bounds>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct Bounds {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

pub async fn list_accessible_apps(limit: usize) -> Result<Vec<AccessibleAppSummary>> {
    let conn = connect().await?;
    let roots = registry_children(&conn).await?;
    let mut apps = Vec::new();

    for object_ref in roots.into_iter().take(limit) {
        if let Ok(proxy) = conn.object_as_accessible(&object_ref).await {
            apps.push(read_app_summary(&proxy, &object_ref).await);
        }
    }

    Ok(apps)
}

pub async fn snapshot_tree(
    app_name_or_bundle_identifier: Option<&str>,
    max_nodes: usize,
    max_depth: u32,
) -> Result<Vec<AccessibilityNode>> {
    let conn = connect().await?;
    let roots = registry_children(&conn).await?;
    let selected_roots = select_roots(&conn, roots, app_name_or_bundle_identifier).await;
    let mut nodes = Vec::new();
    let mut queue = VecDeque::new();

    for object_ref in selected_roots {
        queue.push_back((object_ref, 0_u32, None));
    }

    while let Some((object_ref, depth, parent_index)) = queue.pop_front() {
        if nodes.len() >= max_nodes {
            break;
        }

        let Ok(proxy) = conn.object_as_accessible(&object_ref).await else {
            continue;
        };
        let index = nodes.len() as u32;
        let child_refs = if depth < max_depth {
            proxy.get_children().await.unwrap_or_default()
        } else {
            Vec::new()
        };

        nodes.push(read_node(&proxy, &object_ref, index, parent_index, depth).await);

        for child in child_refs {
            queue.push_back((child, depth + 1, Some(index)));
        }
    }

    Ok(nodes)
}

async fn connect() -> Result<AccessibilityConnection> {
    hydrate_session_bus_env();
    AccessibilityConnection::new()
        .await
        .context("failed to connect to AT-SPI bus")
}

async fn registry_children(conn: &AccessibilityConnection) -> Result<Vec<ObjectRefOwned>> {
    let root = conn
        .root_accessible_on_registry()
        .await
        .context("failed to open AT-SPI registry root")?;
    root.get_children()
        .await
        .context("failed to read AT-SPI registry children")
}

async fn select_roots(
    conn: &AccessibilityConnection,
    roots: Vec<ObjectRefOwned>,
    app_name_or_bundle_identifier: Option<&str>,
) -> Vec<ObjectRefOwned> {
    let Some(needle) = app_name_or_bundle_identifier
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_ascii_lowercase())
    else {
        return roots;
    };

    let mut selected = Vec::new();
    for object_ref in roots {
        if root_matches(conn, &object_ref, &needle).await {
            selected.push(object_ref);
        }
    }

    selected
}

async fn root_matches(
    conn: &AccessibilityConnection,
    object_ref: &ObjectRefOwned,
    needle: &str,
) -> bool {
    let Ok(proxy) = conn.object_as_accessible(object_ref).await else {
        return object_ref_id(object_ref)
            .to_ascii_lowercase()
            .contains(needle);
    };

    if proxy_matches(&proxy, object_ref, needle).await {
        return true;
    }

    let children = proxy.get_children().await.unwrap_or_default();
    for child_ref in children.into_iter().take(8) {
        let Ok(child_proxy) = conn.object_as_accessible(&child_ref).await else {
            continue;
        };
        if proxy_matches(&child_proxy, &child_ref, needle).await {
            return true;
        }
    }

    false
}

async fn proxy_matches(
    proxy: &AccessibleProxy<'_>,
    object_ref: &ObjectRefOwned,
    needle: &str,
) -> bool {
    let name = proxy.name().await.unwrap_or_default();
    let role = proxy.get_role_name().await.unwrap_or_default();
    format!("{} {} {}", object_ref_id(object_ref), name, role)
        .to_ascii_lowercase()
        .contains(needle)
}

async fn read_app_summary(
    proxy: &AccessibleProxy<'_>,
    object_ref: &ObjectRefOwned,
) -> AccessibleAppSummary {
    AccessibleAppSummary {
        object_ref: object_ref_id(object_ref),
        name: optional_string(proxy.name().await.ok()),
        role: role_name(proxy).await,
        child_count: proxy.child_count().await.unwrap_or_default(),
        bounds: bounds(proxy).await,
    }
}

async fn read_node(
    proxy: &AccessibleProxy<'_>,
    object_ref: &ObjectRefOwned,
    index: u32,
    parent_index: Option<u32>,
    depth: u32,
) -> AccessibilityNode {
    AccessibilityNode {
        index,
        parent_index,
        depth,
        object_ref: object_ref_id(object_ref),
        role: role_name(proxy).await,
        name: optional_string(proxy.name().await.ok()),
        description: optional_string(proxy.description().await.ok()),
        child_count: proxy.child_count().await.unwrap_or_default(),
        bounds: bounds(proxy).await,
    }
}

async fn role_name(proxy: &AccessibleProxy<'_>) -> String {
    if let Ok(role) = proxy.get_role_name().await {
        if !role.trim().is_empty() {
            return role;
        }
    }
    proxy
        .get_role()
        .await
        .map(|role| format!("{role:?}"))
        .unwrap_or_else(|_| "unknown".to_string())
}

async fn bounds(proxy: &AccessibleProxy<'_>) -> Option<Bounds> {
    let proxies = proxy.proxies().await.ok()?;
    let component = proxies.component().await.ok()?;
    let (x, y, width, height) = component.get_extents(CoordType::Screen).await.ok()?;
    Some(Bounds {
        x,
        y,
        width,
        height,
    })
}

fn optional_string(value: Option<String>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn object_ref_id(object_ref: &ObjectRefOwned) -> String {
    format!(
        "{}{}",
        object_ref.name_as_str().unwrap_or(""),
        object_ref.path_as_str()
    )
}
