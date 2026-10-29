//! macOS Touch ID / LocalAuthentication integration for Orb.
//!
//! Used to gate revealing, copying, creating, editing, and deleting Bitwarden
//! secrets, as well as updating the Machine Account access token.

use serde::Serialize;

/// Error string returned when the user dismisses the prompt; the UI ignores it.
#[cfg(target_os = "macos")]
pub const CANCELLED: &str = "biometric_cancelled";

#[derive(Debug, Clone, Serialize)]
pub struct BiometricStatus {
    pub available: bool,
    /// `"touch_id"`, `"passcode"`, or `"none"`.
    pub kind: String,
    pub label: String,
}

#[cfg(target_os = "macos")]
#[link(name = "LocalAuthentication", kind = "framework")]
extern "C" {}

#[cfg(target_os = "macos")]
mod macos {
    use super::BiometricStatus;
    use block2::RcBlock;
    use objc2::rc::Retained;
    use objc2::runtime::{AnyClass, AnyObject, Bool};
    use objc2::{class, msg_send};
    use objc2_foundation::{NSError, NSString};
    use std::ptr;
    use std::sync::mpsc;

    /// `LAPolicyDeviceOwnerAuthenticationWithBiometrics = 1`
    const LA_POLICY_BIOMETRICS: isize = 1;
    /// `LAPolicyDeviceOwnerAuthentication = 2` (Touch ID, Apple Watch, or macOS password)
    const LA_POLICY_DEVICE_OWNER: isize = 2;

    unsafe fn new_la_context() -> Option<Retained<AnyObject>> {
        let cls: &AnyClass = class!(LAContext);
        let obj: *mut AnyObject = msg_send![cls, new];
        Retained::from_raw(obj)
    }

    unsafe fn can_evaluate(ctx: &AnyObject, policy: isize) -> bool {
        let mut err: *mut NSError = ptr::null_mut();
        let ok: Bool = msg_send![ctx, canEvaluatePolicy: policy, error: &mut err];
        ok.as_bool()
    }

    pub fn status() -> BiometricStatus {
        unsafe {
            let Some(ctx) = new_la_context() else {
                return BiometricStatus {
                    available: false,
                    kind: "none".to_string(),
                    label: "Unavailable".to_string(),
                };
            };
            if can_evaluate(&ctx, LA_POLICY_BIOMETRICS) {
                return BiometricStatus {
                    available: true,
                    kind: "touch_id".to_string(),
                    label: "Touch ID".to_string(),
                };
            }
            if can_evaluate(&ctx, LA_POLICY_DEVICE_OWNER) {
                return BiometricStatus {
                    available: true,
                    kind: "passcode".to_string(),
                    label: "Touch ID or Mac Password".to_string(),
                };
            }
            BiometricStatus {
                available: false,
                kind: "none".to_string(),
                label: "Unavailable".to_string(),
            }
        }
    }

    pub fn authenticate_blocking(reason: &str) -> Result<(), String> {
        unsafe {
            let Some(ctx) = new_la_context() else {
                return Err("LocalAuthentication is not available on this Mac.".to_string());
            };
            // Prefer LAPolicyDeviceOwnerAuthentication (2) when Touch ID alone is not available
            // (e.g. MacBook in clamshell mode or Apple Watch unlock), or use it directly since
            // macOS presents Touch ID first and offers password fallback cleanly.
            let policy = if can_evaluate(&ctx, LA_POLICY_DEVICE_OWNER) {
                LA_POLICY_DEVICE_OWNER
            } else if can_evaluate(&ctx, LA_POLICY_BIOMETRICS) {
                LA_POLICY_BIOMETRICS
            } else {
                return Err(
                    "Touch ID or device authentication is not configured on this Mac.".to_string(),
                );
            };

            let reason_ns = NSString::from_str(if reason.trim().is_empty() {
                "unlock Bitwarden secrets"
            } else {
                reason.trim()
            });

            let (tx, rx) = mpsc::channel::<Result<(), String>>();
            let block = RcBlock::new(move |success: Bool, error: *mut NSError| {
                if success.as_bool() {
                    let _ = tx.send(Ok(()));
                } else if !error.is_null() {
                    let err_ref = &*error;
                    // LAErrorUserCancel / SystemCancel / AppCancel: the user dismissed the
                    // sheet or macOS interrupted it, which is not an error worth surfacing.
                    if matches!(err_ref.code(), -2 | -4 | -9) {
                        let _ = tx.send(Err(super::CANCELLED.to_string()));
                        return;
                    }
                    let desc = err_ref.localizedDescription().to_string();
                    let _ = tx.send(Err(if desc.is_empty() {
                        "Authentication cancelled.".to_string()
                    } else {
                        desc
                    }));
                } else {
                    let _ = tx.send(Err(super::CANCELLED.to_string()));
                }
            });

            let _: () = msg_send![
                &*ctx,
                evaluatePolicy: policy,
                localizedReason: &*reason_ns,
                reply: &*block
            ];

            rx.recv()
                .map_err(|_| "Authentication prompt was interrupted.".to_string())?
        }
    }
}

#[tauri::command]
pub fn biometric_status() -> BiometricStatus {
    #[cfg(target_os = "macos")]
    {
        macos::status()
    }
    #[cfg(not(target_os = "macos"))]
    {
        BiometricStatus {
            available: false,
            kind: "none".to_string(),
            label: "Unavailable".to_string(),
        }
    }
}

#[tauri::command]
pub async fn biometric_authenticate(reason: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        tauri::async_runtime::spawn_blocking(move || macos::authenticate_blocking(&reason))
            .await
            .map_err(|e| e.to_string())?
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = reason;
        Ok(())
    }
}
