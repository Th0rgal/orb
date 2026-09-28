#[tokio::main]
async fn main() {
    if let Err(error) = sandboxed_sh::control_mcp::client::run().await {
        eprintln!("sandboxed-mcp: {error}");
        std::process::exit(1);
    }
}
