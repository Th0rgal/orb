//
//  ContentView.swift
//  SandboxedDashboard
//
//  Main content view with authentication gate and tab navigation
//

import SwiftUI

struct ContentView: View {
    @State private var isAuthenticated = false
    @State private var isCheckingAuth = true
    @State private var authRequired = false
    @State private var showSetupSheet = false
    @Environment(\.scenePhase) private var scenePhase

    private let api = APIService.shared

    var body: some View {
        Group {
            if isCheckingAuth || api.authRefreshing {
                ProgressView("Connecting...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(OrbStyle.background.ignoresSafeArea())
            } else if api.authSessionExpired {
                ReconnectView()
            } else if authRequired && !isAuthenticated {
                LoginView(
                    sessionExpired: api.authSessionExpired,
                    onLogin: {
                        isAuthenticated = true
                    }
                )
            } else {
                OrbHome()
                    .overlay {
                        // FIDO sign requests arrive on the control stream; the
                        // overlay used to live only in the legacy MainTabView.
                        if !FidoApprovalState.shared.pendingRequests.isEmpty {
                            FidoApprovalOverlay()
                        }
                    }
                    .onAppear { OrbFidoMonitor.shared.update(active: scenePhase == .active) }
                    .onDisappear { OrbFidoMonitor.shared.stop() }
                    .onChange(of: scenePhase) { _, phase in OrbFidoMonitor.shared.update(active: phase == .active) }
                    .onChange(of: api.connectionGeneration) { _, _ in OrbFidoMonitor.shared.update(active: scenePhase == .active) }
            }
        }
        .task {
            await checkAuth()
        }
        .sheet(isPresented: $showSetupSheet) {
            SetupSheet(onComplete: {
                showSetupSheet = false
                Task { await checkAuth() }
            })
        }
        .onChange(of: api.isConfigured) { _, isConfigured in
            // Re-check auth when server URL is configured
            if isConfigured {
                Task { await checkAuth() }
            }
        }
        .onChange(of: api.connectionGeneration) { _, _ in
            Task { await checkAuth() }
        }
        .onChange(of: api.authSessionExpired) { _, expired in
            if expired {
                authRequired = true
                isAuthenticated = false
            }
        }
    }

    private func checkAuth() async {
        // If not configured, show setup sheet
        guard api.isConfigured else {
            isCheckingAuth = false
            showSetupSheet = true
            return
        }

        // Optimistic cold launch: if we already have a non-expired session token,
        // render OrbHome immediately from cache and validate health in parallel.
        if api.isAuthenticated && !api.authSessionExpired {
            isAuthenticated = true
            isCheckingAuth = false
        } else {
            isCheckingAuth = true
        }

        do {
            let _ = try await api.checkHealth()
            authRequired = api.authRequired
            if authRequired && !api.isAuthenticated && !api.authSessionExpired { await api.restoreSavedSession() }
            isAuthenticated = api.isAuthenticated || !authRequired
        } catch {
            // If health check fails, assume we need auth
            authRequired = true
            isAuthenticated = api.isAuthenticated
        }

        isCheckingAuth = false
    }
}

struct ReconnectView: View {
    @State private var reconnecting = false
    var body: some View {
        ContentUnavailableView {
            Label("Reconnect to Orb", systemImage: "lock.circle")
        } description: {
            Text("Your session has expired. Enter your password to continue.")
        } actions: {
            Button("Enter password") { reconnecting = true }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("reconnect")
        }
        .background(OrbStyle.background.ignoresSafeArea())
        .sheet(isPresented: $reconnecting) {
            SetupSheet(onComplete: { reconnecting = false }, allowsDismissal: true)
        }
    }
}

// MARK: - Server and credentials

struct SetupSheet: View {
    let onComplete: () -> Void

    @State private var serverURL = ""
    @State private var isTestingConnection = false
    @State private var password = ""
    @State private var username = UserDefaults.standard.string(forKey: "last_username") ?? ""
    @State private var errorMessage: String?

    private let api = APIService.shared

    var allowsDismissal = false
    var embedded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if embedded { form } else { NavigationStack { form } }
        }
        .onAppear { if serverURL.isEmpty { serverURL = api.baseURL } }
        .presentationDetents(allowsDismissal ? [.medium, .large] : [.large])
        .presentationDragIndicator(allowsDismissal ? .visible : .hidden)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Server URL").font(.subheadline).foregroundStyle(.secondary)
                    TextField("https://your-server.com", text: $serverURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("server-url")
                        .padding(16)
                        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sign in").font(.subheadline).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 16) {
                        if api.authMode == .multiUser {
                            TextField("Username", text: $username).textContentType(.username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Divider()
                        }
                        SecureField("Password", text: $password).textContentType(.password)
                            .accessibilityIdentifier("server-password")
                    }.padding(16)
                        .background(OrbStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                }
                if let errorMessage { Text(errorMessage).font(.subheadline).foregroundStyle(.red) }
            }.padding(20)
        }.background(OrbStyle.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(embedded ? "Backend" : allowsDismissal ? "Server" : "Connect to Orb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if allowsDismissal && !embedded {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() }.disabled(isTestingConnection) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await connectToServer() } } label: {
                        if isTestingConnection { ProgressView() } else { Text("Connect").fontWeight(.semibold) }
                    }.disabled(serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingConnection)
                    .accessibilityLabel("Connect")
                }
            }
            .interactiveDismissDisabled(!allowsDismissal || isTestingConnection)
            .navigationBarBackButtonHidden(embedded && isTestingConnection)
    }

    private func connectToServer() async {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }

        isTestingConnection = true
        errorMessage = nil

        // Save original URL to restore on failure
        let originalURL = api.baseURL
        api.baseURL = trimmedURL

        do {
            _ = try await api.checkHealth()
            if api.authRequired {
                if !password.isEmpty {
                    _ = try await api.login(password: password, username: api.authMode == .multiUser ? username : nil)
                } else if !api.isAuthenticated || api.authSessionExpired {
                    api.baseURL = originalURL
                    errorMessage = "Enter your password to connect."
                    isTestingConnection = false
                    return
                }
            } else { api.authSessionExpired = false }
            password = ""
            api.connectionGeneration += 1
            HapticService.success()
            // No artificial delay before dismissing — the haptic + checkmark
            // already convey success, and adding 500 ms here just felt slow.
            // (UX audit item #24.)
            onComplete()
        } catch {
            // Restore original URL on failure
            api.baseURL = originalURL
            if case APIError.unauthorized = error {
                errorMessage = "Incorrect password. Please try again."
            } else {
                errorMessage = "Could not connect. Check the server address and your connection."
            }
            HapticService.error()
        }

        isTestingConnection = false
    }
}

// MARK: - Login View

struct LoginView: View {
    let sessionExpired: Bool
    let onLogin: () -> Void
    
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var serverURL: String
    
    @FocusState private var isUsernameFocused: Bool
    @FocusState private var isPasswordFocused: Bool
    
    private let api = APIService.shared
    
    init(sessionExpired: Bool = false, onLogin: @escaping () -> Void) {
        self.sessionExpired = sessionExpired
        self.onLogin = onLogin
        _serverURL = State(initialValue: APIService.shared.baseURL)
        _username = State(initialValue: UserDefaults.standard.string(forKey: "last_username") ?? "")
    }
    
    var body: some View {
        ZStack {
            // Background
            Theme.backgroundPrimary.ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 20) {
                    Spacer()
                        .frame(height: 16)
                    
                    // Logo
                    VStack(spacing: 16) {
                        Image(systemName: "brain").resizable().scaledToFit().foregroundStyle(Theme.accent)
                            .frame(width: 40, height: 40)
                        
                        VStack(spacing: 4) {
                            Text("Sign in to Orb")
                                .font(.title2.bold())
                                .foregroundStyle(Theme.textPrimary)
                            
                        }
                    }

                    if sessionExpired {
                        LoginCard(padding: 16, cornerRadius: 18) {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill").resizable().scaledToFit().foregroundStyle(Theme.warning)
                                    .frame(width: 18, height: 18)
                                Text("Session expired. Sign in again to continue.")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    
                    // Login form
                    LoginCard(padding: 20, cornerRadius: 22) {
                        VStack(spacing: 20) {
                            // Server URL field
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Server URL")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.textSecondary)
                                
                                TextField("https://agent-backend.example.com", text: $serverURL)
                                    .textFieldStyle(.plain)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.URL)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .background(Color.white.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(Theme.border, lineWidth: 1)
                                    )
                            }

                            if api.authMode == .multiUser {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Username")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Theme.textSecondary)

                                    TextField("Enter username", text: $username)
                                        .textFieldStyle(.plain)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .focused($isUsernameFocused)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 14)
                                        .background(Color.white.opacity(0.05))
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(isUsernameFocused ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: 1)
                                        )
                                }
                            }
                            
                            // Password field
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Password")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.textSecondary)
                                
                                SecureField("Enter password", text: $password)
                                    .textFieldStyle(.plain)
                                    .focused($isPasswordFocused)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .background(Color.white.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(isPasswordFocused ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: 1)
                                    )
                                    .onSubmit {
                                        login()
                                    }
                            }
                            
                            // Error message
                            if let error = errorMessage {
                                HStack(spacing: 8) {
                                    Image(systemName: "xmark.circle.fill").resizable().scaledToFit().foregroundStyle(Theme.error)
                                        .frame(width: 14, height: 14)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(Theme.error)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            
                            // Login button
                            Button { login() } label: {
                                HStack(spacing: 8) {
                                    if isLoading { ProgressView() } else { Image(systemName: "arrow.right.circle.fill") }
                                    Text("Sign In").fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isLoading || password.isEmpty || (api.authMode == .multiUser && username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        }
                    }
                    .padding(.horizontal, 24)
                    .onAppear {
                        if api.authMode == .multiUser {
                            isUsernameFocused = true
                        } else {
                            isPasswordFocused = true
                        }
                    }
                    .onChange(of: api.authMode) { _, newMode in
                        if newMode == .multiUser {
                            isUsernameFocused = true
                        } else {
                            isPasswordFocused = true
                        }
                    }
                    
                    Spacer()
                }
            }
        }
    }
    
    private func login() {
        guard !password.isEmpty else { return }
        
        // Update server URL
        api.baseURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let usernameValue = api.authMode == .multiUser ? username : nil
                let _ = try await api.login(password: password, username: usernameValue)
                if api.authMode == .multiUser {
                    let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        UserDefaults.standard.set(trimmed, forKey: "last_username")
                    }
                }
                HapticService.success()
                onLogin()
            } catch {
                if let apiError = error as? APIError {
                    switch apiError {
                    case .httpError(let code, _):
                        if code == 401 {
                            errorMessage = api.authMode == .multiUser ? "Invalid username or password" : "Invalid password"
                        } else {
                            errorMessage = apiError.errorDescription
                        }
                    case .unauthorized:
                        errorMessage = api.authMode == .multiUser ? "Invalid username or password" : "Invalid password"
                    default:
                        errorMessage = apiError.errorDescription
                    }
                } else {
                    errorMessage = error.localizedDescription
                }
                HapticService.error()
            }
            isLoading = false
        }
    }
}

private struct LoginCard<Content: View>: View {
    var padding: CGFloat
    var cornerRadius: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(OrbStyle.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(OrbStyle.border, lineWidth: 1))
    }
}

#Preview("Login") {
    LoginView(onLogin: {})
}
