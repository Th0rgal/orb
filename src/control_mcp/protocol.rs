//! Concurrent stdio transport. Request cancellation never cancels a durable action.
use serde_json::{json, Value};
use std::{collections::HashMap, future::Future, sync::Arc};
use tokio::{
    io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt},
    sync::{mpsc, Mutex, Semaphore},
};
use tokio_util::sync::CancellationToken;

fn error(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
}

const MAX_FRAME_BYTES: usize = 1024 * 1024;

// Drain oversized frames without allocating them, so the next request remains
// readable and a peer cannot exhaust memory before the size check.
pub(super) async fn read_frame<R: AsyncBufRead + Unpin>(
    input: &mut R,
) -> std::io::Result<Option<Result<Vec<u8>, ()>>> {
    let mut frame = Vec::new();
    let mut oversized = false;
    loop {
        let available = input.fill_buf().await?;
        if available.is_empty() {
            return Ok(if oversized {
                Some(Err(()))
            } else if frame.is_empty() {
                None
            } else {
                Some(Ok(frame))
            });
        }
        let newline = available.iter().position(|b| *b == b'\n');
        let length = newline.unwrap_or(available.len());
        if !oversized {
            if length > MAX_FRAME_BYTES - frame.len() {
                oversized = true;
                frame.clear();
            } else {
                frame.extend_from_slice(&available[..length]);
            }
        }
        input.consume(length + usize::from(newline.is_some()));
        if newline.is_some() {
            return Ok(Some(if oversized { Err(()) } else { Ok(frame) }));
        }
    }
}

pub async fn serve<R, W, F, Fut>(input: R, mut output: W, handler: F) -> std::io::Result<()>
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin,
    F: Fn(Value) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = Value> + Send + 'static,
{
    let handler = Arc::new(handler);
    let slots = Arc::new(Semaphore::new(8));
    let active = Arc::new(Mutex::new(HashMap::<String, CancellationToken>::new()));
    let (tx, mut rx) = mpsc::channel::<Value>(64);
    let reader = async {
        let mut input = input;
        let mut tasks = tokio::task::JoinSet::new();
        while let Some(line) = read_frame(&mut input).await? {
            let line = match line {
                Ok(line) => line,
                Err(()) => {
                    let _ = tx
                        .send(error(Value::Null, -32600, "Request exceeds 1 MiB"))
                        .await;
                    continue;
                }
            };
            if line.iter().all(u8::is_ascii_whitespace) {
                continue;
            }
            let request: Value = match serde_json::from_slice(&line) {
                Ok(v) => v,
                Err(_) => {
                    let _ = tx.send(error(Value::Null, -32700, "Invalid JSON")).await;
                    continue;
                }
            };
            let id = request.get("id").cloned();
            let method = request.get("method").and_then(Value::as_str).unwrap_or("");
            if id.is_none() {
                if method == "notifications/cancelled" {
                    if let Some(id) = request.pointer("/params/requestId") {
                        if let Some(token) = active.lock().await.get(&id.to_string()) {
                            token.cancel()
                        }
                    }
                }
                continue;
            }
            let id = id.unwrap();
            if request["jsonrpc"] != "2.0"
                || method.is_empty()
                || !(id.is_string() || id.is_number())
            {
                let _ = tx.send(error(id, -32600, "Invalid JSON-RPC request")).await;
                continue;
            }
            let Ok(permit) = slots.clone().try_acquire_owned() else {
                let _ = tx
                    .send(error(
                        id,
                        -32001,
                        "At most eight concurrent requests are allowed",
                    ))
                    .await;
                continue;
            };
            let key = id.to_string();
            let cancellation = CancellationToken::new();
            {
                let mut map = active.lock().await;
                if map.contains_key(&key) {
                    let _ = tx
                        .send(error(id, -32600, "Duplicate active request id"))
                        .await;
                    continue;
                }
                map.insert(key.clone(), cancellation.clone());
            }
            let handler = handler.clone();
            let active = active.clone();
            let tx = tx.clone();
            tasks.spawn(async move {
                let _permit=permit;
                let response=tokio::select!{v=handler(request)=>v,_=cancellation.cancelled()=>error(id,-32800,"Request cancelled; accepted actions continue")};
                active.lock().await.remove(&key);
                let _=tx.send(response).await;
            });
            while tasks.try_join_next().is_some() {}
        }
        while tasks.join_next().await.is_some() {}
        drop(tx);
        Ok::<_, std::io::Error>(())
    };
    let writer = async {
        while let Some(value) = rx.recv().await {
            output.write_all(value.to_string().as_bytes()).await?;
            output.write_all(b"\n").await?;
            output.flush().await?;
        }
        Ok::<_, std::io::Error>(())
    };
    tokio::try_join!(reader, writer)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn slow_request_does_not_block_ping_and_notifications_have_no_response() {
        let input=b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"slow\"}\n{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n";
        let mut output = Vec::new();
        serve(&input[..], &mut output, |v| async move {
            if v["method"] == "slow" {
                tokio::time::sleep(std::time::Duration::from_millis(30)).await
            }
            json!({"jsonrpc":"2.0","id":v["id"],"result":{}})
        })
        .await
        .unwrap();
        let rows: Vec<Value> = String::from_utf8(output)
            .unwrap()
            .lines()
            .map(|s| serde_json::from_str(s).unwrap())
            .collect();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["id"], 2);
        assert_eq!(rows[1]["id"], 1);
    }
    #[tokio::test]
    async fn malformed_json_does_not_close_the_connection() {
        let mut output = Vec::new();
        serve(
            &b"oops\n{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}\n"[..],
            &mut output,
            |v| async move { json!({"jsonrpc":"2.0","id":v["id"],"result":{}}) },
        )
        .await
        .unwrap();
        let rows: Vec<Value> = String::from_utf8(output)
            .unwrap()
            .lines()
            .map(|s| serde_json::from_str(s).unwrap())
            .collect();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["error"]["code"], -32700);
    }
    #[tokio::test]
    async fn oversized_frame_is_drained_and_next_request_survives() {
        let mut input = vec![b'x'; MAX_FRAME_BYTES + 100];
        input.extend_from_slice(b"\n{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}\n");
        let mut output = Vec::new();
        serve(
            tokio::io::BufReader::with_capacity(127, &input[..]),
            &mut output,
            |v| async move { json!({"jsonrpc":"2.0","id":v["id"],"result":{}}) },
        )
        .await
        .unwrap();
        let rows: Vec<Value> = String::from_utf8(output)
            .unwrap()
            .lines()
            .map(|s| serde_json::from_str(s).unwrap())
            .collect();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["error"]["code"], -32600);
        assert_eq!(rows[1]["id"], 3);
    }
    #[tokio::test]
    async fn cancellation_releases_a_request_without_closing_transport() {
        let input=b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"slow\"}\n{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1}}\n";
        let mut output = Vec::new();
        tokio::time::timeout(
            std::time::Duration::from_secs(1),
            serve(&input[..], &mut output, |_| async {
                std::future::pending::<Value>().await
            }),
        )
        .await
        .unwrap()
        .unwrap();
        let response: Value = serde_json::from_slice(&output).unwrap();
        assert_eq!(response["id"], 1);
        assert_eq!(response["error"]["code"], -32800);
    }
    #[tokio::test]
    async fn ninth_concurrent_request_is_rejected_and_all_slots_cancel_cleanly() {
        let mut input = String::new();
        for id in 0..9 {
            input.push_str(&json!({"jsonrpc":"2.0","id":id,"method":"slow"}).to_string());
            input.push('\n');
        }
        for id in 0..8 {
            input.push_str(&json!({"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":id}}).to_string());
            input.push('\n');
        }
        let mut output = Vec::new();
        tokio::time::timeout(
            std::time::Duration::from_secs(1),
            serve(input.as_bytes(), &mut output, |_| async {
                std::future::pending::<Value>().await
            }),
        )
        .await
        .unwrap()
        .unwrap();
        let rows: Vec<Value> = String::from_utf8(output)
            .unwrap()
            .lines()
            .map(|s| serde_json::from_str(s).unwrap())
            .collect();
        assert_eq!(rows.len(), 9);
        assert_eq!(
            rows.iter().filter(|v| v["error"]["code"] == -32001).count(),
            1
        );
        assert_eq!(
            rows.iter().filter(|v| v["error"]["code"] == -32800).count(),
            8
        );
    }
}
