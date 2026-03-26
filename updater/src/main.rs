mod app;
mod builder;
mod cli;
mod config;
mod install;
mod liveness;
mod logging;
mod notify;
mod state;
mod upstream;

use anyhow::Result;
use clap::Parser;

#[tokio::main]
async fn main() -> Result<()> {
    let cli = cli::Cli::parse();
    app::run(cli).await
}
