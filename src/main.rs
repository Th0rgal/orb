//! sandboxed.sh - HTTP Server Entry Point
//!
//! Starts the HTTP server that exposes the agent API.

use sandboxed_sh::{api, config::Config, env_crypto};
use tracing::{info, warn};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

fn main() -> anyhow::Result<()> {
    // Use a custom tokio runtime with larger worker thread stacks (16 MB instead of default 2 MB).
    // Deep async call chains in the mission runner (workspace prep → config write → nspawn exec)
    // can overflow the default 2 MB worker stack.
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_stack_size(16 * 1024 * 1024)
        .build()?;
    // `sandboxed-sh deploy --service <unit>`: operator deploy over SSH, the
    // same routine as `POST /api/system/deploy` (see DEBUGGING.md).
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("deploy") {
        let code = runtime.block_on(api::system::run_deploy_cli(&args[1..]));
        std::process::exit(code);
    }
    runtime.block_on(async_main())
}

async fn async_main() -> anyhow::Result<()> {
    // Initialize logging
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "sandboxed_sh=debug,tower_http=debug".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    // Load configuration
    let config = Config::from_env()?;
    info!(
        "Loaded configuration: model={}",
        config
            .default_model
            .as_deref()
            .unwrap_or("(opencode default)")
    );
    match api::system::reconcile_hermes_service_drain_policy(&config).await {
        Ok(true) => info!("Migrated Hermes service to drain-safe mixed kill mode"),
        Ok(false) => {}
        Err(error) => warn!(
            "Could not reconcile Hermes service drain policy: {}. Existing Hermes configuration was left unchanged.",
            error
        ),
    }
    let context_root = config
        .context
        .context_dir(&config.working_dir.to_string_lossy());
    std::env::set_var("SANDBOXED_SH_CONTEXT_ROOT", &context_root);
    std::env::set_var(
        "SANDBOXED_SH_CONTEXT_DIR_NAME",
        &config.context.context_dir_name,
    );
    let runtime_workspace_file = config
        .working_dir
        .join(".sandboxed-sh")
        .join("runtime")
        .join("current_workspace.json");
    std::env::set_var(
        "SANDBOXED_SH_RUNTIME_WORKSPACE_FILE",
        runtime_workspace_file.to_string_lossy().to_string(),
    );

    // Initialize encryption key (ensures key is available for library operations)
    match env_crypto::ensure_private_key().await {
        Ok(_) => info!("Encryption key initialized"),
        Err(e) => warn!(
            "Could not initialize encryption key: {}. Library encryption will be unavailable.",
            e
        ),
    }

    // Start HTTP server
    let addr = format!("{}:{}", config.host, config.port);
    info!("Starting server on {}", addr);

    api::serve(config).await?;

    Ok(())
}
