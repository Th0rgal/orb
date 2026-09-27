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

    private let api = APIService.shared

    var body: some View {
        Group {
            if isCheckingAuth {
                LoadingView(message: "Connecting...")
                    .background(Theme.backgroundPrimary.ignoresSafeArea())
            } else if authRequired && (!isAuthenticated || api.authSessionExpired) {
                LoginView(
                    sessionExpired: api.authSessionExpired,
                    onLogin: {
                        isAuthenticated = true
                    }
                )
            } else {
                OrbHome()
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
        .onChange(of: api.authSessionExpired) { _, expired in
            if expired {
                authRequired = true
                isAuthenticated = false
            }
        }
    }

    private func checkAuth() async {
        isCheckingAuth = true

        // If not configured, show setup sheet
        guard api.isConfigured else {
            isCheckingAuth = false
            showSetupSheet = true
            return
        }

        do {
            let _ = try await api.checkHealth()
            authRequired = api.authRequired
            isAuthenticated = api.isAuthenticated || !authRequired
        } catch {
            // If health check fails, assume we need auth
            authRequired = true
            isAuthenticated = api.isAuthenticated
        }

        isCheckingAuth = false
    }
}

// MARK: - Setup Sheet (First Launch)

struct SetupSheet: View {
    let onComplete: () -> Void

    @State private var serverURL = ""
    @State private var isTestingConnection = false
    @State private var connectionSuccess = false
    @State private var errorMessage: String?

    private let api = APIService.shared

    var allowsDismissal = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Server URL") {
                    TextField("https://your-server.com", text: $serverURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("server-url")
                }
                if let errorMessage { Text(errorMessage).font(.subheadline).foregroundStyle(.red) }
                Section {
                    Button { Task { await connectToServer() } } label: {
                        HStack { Text(isTestingConnection ? "Connecting…" : "Connect"); Spacer(); if isTestingConnection { ProgressView() } }
                    }.disabled(serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingConnection)
                }
            }.scrollContentBackground(.hidden).background(OrbStyle.background)
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(allowsDismissal ? "Server" : "Connect to Orb")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { if allowsDismissal { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.disabled(isTestingConnection) } } }
                .interactiveDismissDisabled(!allowsDismissal || isTestingConnection)
        }
        .onAppear { if serverURL.isEmpty { serverURL = api.baseURL } }
        .presentationDetents(allowsDismissal ? [.medium, .large] : [.large])
        .presentationDragIndicator(allowsDismissal ? .visible : .hidden)
    }

    private func connectToServer() async {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }

        isTestingConnection = true
        errorMessage = nil
        connectionSuccess = false

        // Save original URL to restore on failure
        let originalURL = api.baseURL
        api.baseURL = trimmedURL

        do {
            _ = try await api.checkHealth()
            connectionSuccess = true
            HapticService.success()
            // No artificial delay before dismissing — the haptic + checkmark
            // already convey success, and adding 500 ms here just felt slow.
            // (UX audit item #24.)
            onComplete()
        } catch {
            // Restore original URL on failure
            api.baseURL = originalURL
            errorMessage = "Could not connect. Please check the URL."
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
                        PhosphorIcon(symbol: .brain, weight: .light, color: Theme.accent)
                            .frame(width: 40, height: 40)
                        
                        VStack(spacing: 4) {
                            Text("Sign in to Orb")
                                .font(.title2.bold())
                                .foregroundStyle(Theme.textPrimary)
                            
                        }
                    }

                    if sessionExpired {
                        GlassCard(padding: 16, cornerRadius: 18) {
                            HStack(spacing: 10) {
                                PhosphorIcon(symbol: .warning, weight: .fill, color: Theme.warning)
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
                    GlassCard(padding: 20, cornerRadius: 22) {
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
                                    PhosphorIcon(symbol: .xCircle, weight: .fill, color: Theme.error)
                                        .frame(width: 14, height: 14)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(Theme.error)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            
                            // Login button
                            GlassPrimaryButton(
                                "Sign In",
                                phosphorIcon: .signIn,
                                isLoading: isLoading,
                                isDisabled: password.isEmpty || (api.authMode == .multiUser && username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            ) {
                                login()
                            }
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

// MARK: - Main Tab View

struct MainTabView: View {
    private var nav = NavigationState.shared
    
    enum TabItem: String, CaseIterable {
        case control = "Control"
        case projects = "Projects"
        case terminal = "Terminal"
        case files = "Files"

        var icon: String {
            switch self {
            case .control: return "message.fill"
            case .projects: return "square.stack.3d.up.fill"
            case .terminal: return "terminal.fill"
            case .files: return "folder.fill"
            }
        }
    }
    
    var body: some View {
        TabView(selection: Binding(
            get: { nav.selectedTab },
            set: { nav.selectedTab = $0 }
        )) {
            ForEach(TabItem.allCases, id: \.rawValue) { tab in
                NavigationStack {
                    tabContent(for: tab)
                }
                .tabItem {
                    Label(tab.rawValue, systemImage: tab.icon)
                }
                .tag(tab)
            }
        }
        .tint(Theme.accent)
        .overlay {
            if !FidoApprovalState.shared.pendingRequests.isEmpty {
                FidoApprovalOverlay()
            }
        }
    }
    
    @ViewBuilder
    private func tabContent(for tab: TabItem) -> some View {
        switch tab {
        case .control:
            ControlView()
        case .projects:
            ProjectsView()
        case .terminal:
            TerminalView()
        case .files:
            FilesView()
        }
    }
}

#Preview("Login") {
    LoginView(onLogin: {})
}

#Preview("Main") {
    MainTabView()
}
