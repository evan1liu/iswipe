import SwiftUI
import Combine
import WebKit

// --- DATA MODELS ---

struct Todo: Identifiable, Codable {
    let id = UUID()
    let title: String
    let notes: String?
    let due_date: String?
    let priority: Int
    let isCompleted: Bool
    
    enum CodingKeys: String, CodingKey {
        case title, notes, due_date, priority, isCompleted
    }
}

struct Event: Identifiable, Codable {
    let id = UUID()
    let title: String
    let notes: String?
    let location: String?
    let start_date: String?
    let end_date: String?
    let all_day: Bool
    
    enum CodingKeys: String, CodingKey {
        case title, notes, location, start_date, end_date, all_day
    }
}

struct Email: Identifiable, Codable {
    let id: String // API now returns ID, though we might just generate one on backend if not provided
    let from_addr: String
    let subject: String
    let date: String
    let preview: String
    let body_html: String
    let summary: String?
    let category: String?
    let todos: [Todo]
    let events: [Event]
    
    enum CodingKeys: String, CodingKey {
        case id
        case from_addr
        case subject
        case date
        case preview
        case body_html
        case summary
        case category
        case todos
        case events
    }
}

// --- VIEW MODELS ---

// Represents a single email card in the deck
struct EmailCard: Identifiable {
    let id = UUID()
    let email: Email

    var hasSubcards: Bool {
        return !email.events.isEmpty || !email.todos.isEmpty
    }

    var totalSubcards: Int {
        return email.events.count + email.todos.count
    }
}

// Batch status response
struct BatchStatus: Codable {
    let status: String
    let message: String
    let last_updated: String?
    let count: Int
}

struct AuthResponse: Codable {
    let user_code: String
    let verification_uri: String
    let message: String
}

struct AuthStatusResponse: Codable {
    let is_logged_in: Bool
    let status: String?
    let error: String?
}

// MARK: - Operation History for Undo/Redo

enum SwipeOperation {
    case swipeLeft(card: EmailCard, emailId: String)  // Deleted email
    case swipeRight(card: EmailCard, addedToCalendar: Bool, addedToReminders: Bool)  // Saved card
}

class OperationHistory: ObservableObject {
    @Published var undoStack: [SwipeOperation] = []
    @Published var redoStack: [SwipeOperation] = []

    var canUndo: Bool {
        !undoStack.isEmpty
    }

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    func recordOperation(_ operation: SwipeOperation) {
        undoStack.append(operation)
        redoStack.removeAll()  // Clear redo stack when new operation is performed
    }

    func undo() -> SwipeOperation? {
        guard let operation = undoStack.popLast() else { return nil }
        redoStack.append(operation)
        return operation
    }

    func redo() -> SwipeOperation? {
        guard let operation = redoStack.popLast() else { return nil }
        undoStack.append(operation)
        return operation
    }
}

class EmailViewModel: ObservableObject {
    @Published var cards: [EmailCard] = []
    @Published var currentIndex: Int = 0
    @Published var isLoading = false
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published var statusMessage: String = ""
    @Published var batchStatus: String = "idle"  // idle, fetching, processing, completed, error
    @Published var slideDirection: SlideDirection = .forward

    // Auth State
    @Published var isLoggedIn = false
    @Published var loginCode: String?
    @Published var loginUrl: String?
    @Published var isWaitingForLogin = false

    // Subcard state
    @Published var isInSubcardMode = false
    @Published var currentSubcardIndex = 0

    enum SlideDirection {
        case forward
        case backward
    }
    
    // IMPORTANT: Change this to your computer's local IP address when testing on a real device
    // To find your IP: Open Terminal and run: ifconfig | grep "inet " | grep -v 127.0.0.1
    // Use 127.0.0.1 for simulator, your local IP (e.g., 192.168.1.x) for real device
    private let baseURL = "http://10.140.204.85:8000"  // Your computer's IP for real device
    
    func checkAuth() {
        guard let url = URL(string: "\(baseURL)/auth/status") else { return }
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                if let data = data, let status = try? JSONDecoder().decode(AuthStatusResponse.self, from: data) {
                    self.isLoggedIn = status.is_logged_in
                    if self.isLoggedIn {
                        self.fetchProcessedEmails()
                    }
                }
            }
        }.resume()
    }

    func startLogin() {
        guard let url = URL(string: "\(baseURL)/auth/start") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        isLoading = true
        errorMessage = nil
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                self.isLoading = false
                if let error = error {
                    self.errorMessage = "Login failed: \(error.localizedDescription)"
                    return
                }
                
                guard let data = data else { return }
                
                do {
                    let authData = try JSONDecoder().decode(AuthResponse.self, from: data)
                    self.loginCode = authData.user_code
                    self.loginUrl = authData.verification_uri
                    self.isWaitingForLogin = true
                    
                    // Start polling
                    self.pollAuthStatus()
                } catch {
                    self.errorMessage = "Failed to decode auth response"
                }
            }
        }.resume()
    }
    
    func pollAuthStatus() {
        guard isWaitingForLogin else { return }
        
        // Poll every 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard self.isWaitingForLogin else { return }
            
            guard let url = URL(string: "\(self.baseURL)/auth/status") else { return }
            
            URLSession.shared.dataTask(with: url) { data, response, error in
                DispatchQueue.main.async {
                    if let data = data, let status = try? JSONDecoder().decode(AuthStatusResponse.self, from: data) {
                        if status.is_logged_in {
                            self.isLoggedIn = true
                            self.isWaitingForLogin = false
                            self.loginCode = nil
                            self.fetchProcessedEmails()
                        } else if status.status == "error" {
                            self.isWaitingForLogin = false
                            self.errorMessage = status.error
                        } else {
                            // Keep polling
                            self.pollAuthStatus()
                        }
                    } else {
                        self.pollAuthStatus()
                    }
                }
            }.resume()
        }
    }
    
    func startEmailRefresh() {
        // Trigger the refresh endpoint (returns immediately)
        guard let url = URL(string: "\(baseURL)/refresh-emails") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        isRefreshing = true
        errorMessage = nil
        statusMessage = "Refresh started..."
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.isRefreshing = false
                    self.errorMessage = "Refresh failed: \(error.localizedDescription)"
                    return
                }
                
                // Successfully started - now user can manually check status
                self.statusMessage = "Refresh started! Press 'Check Status' to see progress."
                self.isRefreshing = false
                self.batchStatus = "processing"
            }
        }.resume()
    }
    
    func checkRefreshStatus() {
        guard let url = URL(string: "\(baseURL)/refresh-status") else { return }
        
        isLoading = true
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                self.isLoading = false
                
                guard let data = data, error == nil else {
                    self.errorMessage = "Failed to check status"
                    return
                }
                
                do {
                    let status = try JSONDecoder().decode(BatchStatus.self, from: data)
                    self.batchStatus = status.status
                    self.statusMessage = status.message
                    
                    switch status.status {
                    case "completed":
                        // Auto-fetch the processed emails
                        self.fetchProcessedEmails()
                    case "error":
                        self.errorMessage = status.message
                    default:
                        break
                    }
                } catch {
                    self.errorMessage = "Failed to decode status: \(error.localizedDescription)"
                }
            }
        }.resume()
    }
    
    func fetchProcessedEmails() {
        guard let url = URL(string: "\(baseURL)/processed-emails") else { return }
        
        isLoading = true
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                self.isLoading = false
                self.statusMessage = ""
                
                if let error = error {
                    self.errorMessage = "Error: \(error.localizedDescription)"
                    return
                }
                
                guard let data = data else { return }
                
                do {
                    let emails = try JSONDecoder().decode([Email].self, from: data)
                    self.buildCards(from: emails)
                    if emails.isEmpty {
                        self.statusMessage = "No todos or events found in your emails."
                    }
                } catch {
                    self.errorMessage = "Failed to decode emails: \(error.localizedDescription)"
                }
            }
        }.resume()
    }
    
    private func buildCards(from emails: [Email]) {
        // Create one card per email (newest to oldest, past 7 days only)
        // The backend should already filter to 7 days, but we create cards for all returned emails
        var newCards: [EmailCard] = []

        for email in emails {
            newCards.append(EmailCard(email: email))
        }

        self.cards = newCards
        self.currentIndex = 0
        self.isInSubcardMode = false
        self.currentSubcardIndex = 0
    }
    
    func nextCard() {
        if currentIndex < cards.count - 1 {
            slideDirection = .forward
            currentIndex += 1
        }
    }
    
    func previousCard() {
        if currentIndex > 0 {
            slideDirection = .backward
            currentIndex -= 1
        }
    }
    
    func removeCurrentCard() {
        guard !cards.isEmpty && currentIndex < cards.count else { return }
        cards.remove(at: currentIndex)
        // If we removed the last card, adjust index
        if currentIndex >= cards.count && currentIndex > 0 {
            currentIndex -= 1
        }
    }

    func deleteEmail(emailId: String) {
        guard let url = URL(string: "\(baseURL)/delete-email/\(emailId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Failed to delete email: \(error.localizedDescription)")
                } else {
                    print("Email deleted successfully")
                }
            }
        }.resume()
    }

    func restoreEmail(emailId: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(baseURL)/restore-email/\(emailId)") else {
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Failed to restore email: \(error.localizedDescription)")
                    completion(false)
                } else {
                    print("Email restored successfully")
                    completion(true)
                }
            }
        }.resume()
    }
}

// --- VIEWS ---

struct SavedCardView: View {
    let card: EmailCard
    let onDelete: () -> Void
    @State private var showingOriginalEmail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.email.subject)
                .font(.headline)
                .lineLimit(2)

            HStack {
                Text(card.email.category ?? "Uncategorized")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(categoryColor(for: card.email.category ?? "Uncategorized").opacity(0.2))
                    .foregroundColor(categoryColor(for: card.email.category ?? "Uncategorized"))
                    .cornerRadius(8)

                Spacer()

                Button(action: {
                    onDelete()
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .padding()
        .frame(width: 200)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 4)
        .onTapGesture {
            showingOriginalEmail = true
        }
        .sheet(isPresented: $showingOriginalEmail) {
            NavigationView {
                WebView(htmlContent: card.email.body_html)
                    .navigationTitle("Original Email")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                showingOriginalEmail = false
                            }
                        }
                    }
            }
        }
    }

    func categoryColor(for category: String) -> Color {
        switch category.lowercased() {
        case "work":
            return .blue
        case "personal":
            return .green
        case "finance":
            return .orange
        case "travel":
            return .purple
        case "shopping":
            return .pink
        default:
            return .gray
        }
    }
}

struct EmailCardView: View {
    let card: EmailCard
    let isInSubcardMode: Bool
    let subcardIndex: Int
    let onAddToCalendar: (Event) -> Void
    let onAddToReminder: (Todo) -> Void
    let onSkip: () -> Void
    @State private var showingOriginalEmail = false

    var body: some View {
        VStack(spacing: 20) {
            if isInSubcardMode {
                // Show subcard (event or todo)
                subcardView
            } else {
                // Show email summary
                emailSummaryView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(UIColor.systemBackground).opacity(0.95),
                    Color(UIColor.secondarySystemBackground).opacity(0.9)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(20)
        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 8)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            cardBorderColor(for: card.email.category ?? "Uncategorized"),
                            cardBorderColor(for: card.email.category ?? "Uncategorized").opacity(0.6)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
        )
        .padding()
        .sheet(isPresented: $showingOriginalEmail) {
            NavigationView {
                WebView(htmlContent: card.email.body_html)
                    .navigationTitle("Original Email")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                showingOriginalEmail = false
                            }
                        }
                    }
            }
        }
    }

    var emailSummaryView: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 60, height: 60)
                .foregroundColor(.blue)

            // Summary
            Text(card.email.summary ?? "No summary available")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .lineLimit(8)

            Spacer()

            // View Original Email Button
            Button(action: {
                showingOriginalEmail = true
            }) {
                HStack {
                    Image(systemName: "envelope.open")
                    Text("View Original Email")
                }
                .font(.subheadline)
                .foregroundColor(.blue)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(20)
            }
        }
        .padding()
    }

    var subcardView: some View {
        VStack(spacing: 20) {
            if subcardIndex < card.email.events.count {
                // Event subcard
                let event = card.email.events[subcardIndex]
                eventSubcardView(event)
            } else {
                // Todo subcard
                let todoIndex = subcardIndex - card.email.events.count
                if todoIndex < card.email.todos.count {
                    let todo = card.email.todos[todoIndex]
                    todoSubcardView(todo)
                }
            }
        }
        .padding()
    }

    func eventSubcardView(_ event: Event) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "calendar")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 60, height: 60)
                .foregroundColor(.blue)

            Text("Event Detected")
                .font(.headline)
                .foregroundColor(.secondary)

            Text(event.title)
                .font(.title2)
                .bold()
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                if let location = event.location, !location.isEmpty {
                    HStack {
                        Image(systemName: "mappin.and.ellipse")
                        Text(location)
                    }
                }

                if let startDate = event.start_date, let endDate = event.end_date {
                    HStack {
                        Image(systemName: "clock")
                        Text("\(startDate) - \(endDate)")
                    }
                } else if let startDate = event.start_date {
                    HStack {
                        Image(systemName: "clock")
                        Text(startDate)
                    }
                }

                if let notes = event.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.body)
                        .padding(.top, 5)
                        .lineLimit(3)
                }
            }
            .font(.subheadline)
            .padding()
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(8)

            Spacer()

            // Action buttons
            HStack(spacing: 20) {
                Button(action: {
                    onSkip()
                }) {
                    Text("Skip")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray)
                        .cornerRadius(12)
                }

                Button(action: {
                    onAddToCalendar(event)
                }) {
                    Text("Add to Calendar")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                }
            }
            .padding(.horizontal)
        }
    }

    func todoSubcardView(_ todo: Todo) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checklist")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 60, height: 60)
                .foregroundColor(.green)

            Text("Todo Detected")
                .font(.headline)
                .foregroundColor(.secondary)

            Text(todo.title)
                .font(.title2)
                .bold()
                .multilineTextAlignment(.center)

            if let deadline = todo.due_date, !deadline.isEmpty {
                HStack {
                    Image(systemName: "hourglass")
                    Text("Due: \(deadline)")
                }
                .font(.subheadline)
                .foregroundColor(.red)
            }

            if let notes = todo.notes, !notes.isEmpty {
                Text(notes)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding()
                    .lineLimit(3)
            }

            Spacer()

            // Action buttons
            HStack(spacing: 20) {
                Button(action: {
                    onSkip()
                }) {
                    Text("Skip")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray)
                        .cornerRadius(12)
                }

                Button(action: {
                    onAddToReminder(todo)
                }) {
                    Text("Add to Reminders")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .cornerRadius(12)
                }
            }
            .padding(.horizontal)
        }
    }

    func cardBorderColor(for category: String) -> Color {
        switch category.lowercased() {
        case "work":
            return .blue
        case "personal":
            return .green
        case "finance":
            return .orange
        case "travel":
            return .purple
        case "shopping":
            return .pink
        default:
            return .gray
        }
    }
}

struct ContentView: View {
    @StateObject var viewModel = EmailViewModel()
    @StateObject var eventService = IntegratedEventService()
    @StateObject var operationHistory = OperationHistory()

    // Mode selection
    @State private var selectedMode: DisplayMode = .swipe

    // Gesture State
    @State private var offset = CGSize.zero

    // Saved cards storage
    @State private var savedCards: [EmailCard] = []

    enum DisplayMode: String, CaseIterable {
        case swipe = "Swipe"
        case saved = "Saved"
    }

    var body: some View {
        Group {
            if viewModel.isLoggedIn {
                mainInterface
            } else {
                loginInterface
            }
        }
        .onAppear {
            viewModel.checkAuth()
        }
    }

    var loginInterface: some View {
        VStack(spacing: 30) {
            Text("Hello, Welcome to iSwipe")
                .font(.largeTitle)
                .bold()
            
            if let code = viewModel.loginCode, let url = viewModel.loginUrl {
                VStack(spacing: 20) {
                    Text("Please login to your Microsoft Account")
                        .font(.headline)
                    
                    Text("1. Copy this code:")
                        .foregroundColor(.secondary)
                    
                    Text(code)
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(10)
                        .onTapGesture {
                            UIPasteboard.general.string = code
                            let impactMed = UIImpactFeedbackGenerator(style: .medium)
                            impactMed.impactOccurred()
                        }
                    
                    Text("(Tap code to copy)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("2. Open the login page:")
                        .foregroundColor(.secondary)
                    
                    Link("Open Login Page", destination: URL(string: url)!)
                        .font(.headline)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    
                    if viewModel.isWaitingForLogin {
                        VStack {
                            ProgressView()
                            Text("Waiting for you to login...")
                                .foregroundColor(.secondary)
                        }
                        .padding(.top)
                    }
                }
                .padding()
                .background(Color(UIColor.systemBackground))
                .cornerRadius(20)
                .shadow(radius: 5)
                .padding()
                
            } else {
                if viewModel.isLoading {
                    ProgressView()
                } else {
                    Button("Login with Microsoft") {
                        viewModel.startLogin()
                    }
                    .font(.title2)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.all))
    }

    var mainInterface: some View {
        VStack(spacing: 0) {
            // Top bar with Undo/Redo and Segmented Control
            VStack(spacing: 16) {
                // Undo/Redo buttons
                HStack {
                    HStack(spacing: 12) {
                        Button(action: performUndo) {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .font(.title2)
                                .foregroundColor(operationHistory.canUndo ? .blue : .gray)
                        }
                        .disabled(!operationHistory.canUndo)

                        Button(action: performRedo) {
                            Image(systemName: "arrow.uturn.forward.circle.fill")
                                .font(.title2)
                                .foregroundColor(operationHistory.canRedo ? .blue : .gray)
                        }
                        .disabled(!operationHistory.canRedo)
                    }
                    .padding(.leading)

                    Spacer()
                }
                .padding(.top, 8)

                // Segmented Control
                Picker("Mode", selection: $selectedMode) {
                    ForEach(DisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
            }
            .padding(.bottom, 8)

            if viewModel.isLoading || viewModel.isRefreshing {
                VStack(spacing: 16) {
                    ProgressView()
                    if !viewModel.statusMessage.isEmpty {
                        Text(viewModel.statusMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 16) {
                    Text("Error").font(.headline)
                    Text(error).foregroundColor(.red).padding()
                    
                    HStack(spacing: 16) {
                        Button("Retry Fetch") {
                            viewModel.fetchProcessedEmails()
                        }
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        
                        Button("Start New Refresh") {
                            viewModel.errorMessage = nil
                            viewModel.startEmailRefresh()
                        }
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
            } else if viewModel.cards.isEmpty && selectedMode == .swipe {
                emptySwipeView
            } else {
                // Main content based on selected mode
                if selectedMode == .swipe {
                    swipeView
                } else {
                    savedView
                }
            }
        }
        .background(Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.all))
    }

    var emptySwipeView: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .foregroundColor(.gray)

            Text("No processed emails found.")
                .font(.headline)

            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            VStack(spacing: 12) {
                Button("Start Email Refresh") {
                    viewModel.startEmailRefresh()
                }
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)

                if viewModel.batchStatus == "processing" || viewModel.batchStatus == "fetching" {
                    Button("Check Status") {
                        viewModel.checkRefreshStatus()
                    }
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }

                Button("Load Existing") {
                    viewModel.fetchProcessedEmails()
                }
                .padding()
                .background(Color.gray)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
        }
        .padding()
    }

    var swipeView: some View {
        VStack(spacing: 0) {
            // Category label
            if !viewModel.cards.isEmpty {
                Text(viewModel.cards[viewModel.currentIndex].email.category ?? "Uncategorized")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(categoryColor(for: viewModel.cards[viewModel.currentIndex].email.category ?? "Uncategorized").opacity(0.2))
                    .foregroundColor(categoryColor(for: viewModel.cards[viewModel.currentIndex].email.category ?? "Uncategorized"))
                    .cornerRadius(16)
                    .padding(.bottom, 8)
            }

            VStack(spacing: 0) {
                // Top Header: Email Subject (Fixed, doesn't move with subcards)
                Text(viewModel.cards[viewModel.currentIndex].email.subject)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(UIColor.secondarySystemBackground))
                    .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 2)
                    .zIndex(1) // Keep on top

                Spacer()

                // Middle: Card Deck with Swipe Gestures
                ZStack {
                    // Show next card below for visual effect
                    if viewModel.currentIndex < viewModel.cards.count - 1 {
                        EmailCardView(
                            card: viewModel.cards[viewModel.currentIndex + 1],
                            isInSubcardMode: false,
                            subcardIndex: 0,
                            onAddToCalendar: { _ in },
                            onAddToReminder: { _ in },
                            onSkip: { }
                        )
                        .scaleEffect(0.95)
                        .offset(y: 10)
                    }

                    // Current Card
                    EmailCardView(
                        card: viewModel.cards[viewModel.currentIndex],
                        isInSubcardMode: viewModel.isInSubcardMode,
                        subcardIndex: viewModel.currentSubcardIndex,
                        onAddToCalendar: handleAddToCalendar,
                        onAddToReminder: handleAddToReminder,
                        onSkip: handleSkipSubcard
                    )
                    .offset(x: viewModel.isInSubcardMode ? 0 : offset.width, y: 0)
                    .rotationEffect(.degrees(viewModel.isInSubcardMode ? 0 : Double(offset.width / 20)))
                    .gesture(
                        viewModel.isInSubcardMode ? nil :
                        DragGesture()
                            .onChanged { gesture in
                                offset = gesture.translation
                            }
                            .onEnded { _ in
                                if offset.width > 100 {
                                    handleSwipeRight()
                                } else if offset.width < -100 {
                                    handleSwipeLeft()
                                } else {
                                    withAnimation { offset = .zero }
                                }
                            }
                    )
                }

                Spacer()

                // Success/Error Messages
                if let msg = eventService.lastSuccessMessage {
                    Text(msg).foregroundColor(.green).font(.caption).padding()
                }
                if let err = eventService.lastError {
                    Text(err.localizedDescription).foregroundColor(.red).font(.caption).padding()
                }

                // Card counter at bottom
                if viewModel.isInSubcardMode {
                    Text("Item \(viewModel.currentSubcardIndex + 1) of \(viewModel.cards[viewModel.currentIndex].totalSubcards)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 30)
                } else {
                    Text("\(viewModel.currentIndex + 1) / \(viewModel.cards.count)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 30)
                }
            }
        }
    }

    var savedView: some View {
        ScrollView {
            if savedCards.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "archivebox")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                        .foregroundColor(.gray)

                    Text("No saved emails yet")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text("Swipe right on emails to save them here")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Group saved cards by category
                let groupedCards = Dictionary(grouping: savedCards) { card in
                    card.email.category ?? "Uncategorized"
                }

                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(groupedCards.keys.sorted()), id: \.self) { category in
                        VStack(alignment: .leading, spacing: 12) {
                            // Category header
                            HStack {
                                Text(category)
                                    .font(.headline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(categoryColor(for: category).opacity(0.2))
                                    .foregroundColor(categoryColor(for: category))
                                    .cornerRadius(16)

                                Spacer()

                                Text("\(groupedCards[category]?.count ?? 0)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal)

                            // Horizontal scroll of cards
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(groupedCards[category] ?? []) { card in
                                        SavedCardView(card: card, onDelete: {
                                            withAnimation {
                                                savedCards.removeAll { $0.id == card.id }
                                            }
                                        })
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
        }
    }

    // MARK: - Helper Functions

    func categoryColor(for category: String) -> Color {
        // Placeholder color system - will be enhanced later
        switch category.lowercased() {
        case "work":
            return .blue
        case "personal":
            return .green
        case "finance":
            return .orange
        case "travel":
            return .purple
        case "shopping":
            return .pink
        default:
            return .gray
        }
    }

    // MARK: - Undo/Redo Functions

    func performUndo() {
        guard let operation = operationHistory.undo() else { return }

        switch operation {
        case .swipeLeft(let card, let emailId):
            // Undo delete: restore email and add card back
            viewModel.restoreEmail(emailId: emailId) { success in
                if success {
                    // Re-add card to deck
                    viewModel.cards.insert(card, at: viewModel.currentIndex)
                    eventService.lastSuccessMessage = "Email restored"

                    // Clear message after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        eventService.lastSuccessMessage = nil
                    }
                }
            }

        case .swipeRight(let card, _, _):
            // Undo save: remove from saved section and add back to deck
            withAnimation {
                savedCards.removeAll { $0.id == card.id }
            }
            // Re-add card to current position
            viewModel.cards.insert(card, at: viewModel.currentIndex)
            eventService.lastSuccessMessage = "Unsaved"

            // Clear message after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                eventService.lastSuccessMessage = nil
            }
        }
    }

    func performRedo() {
        guard let operation = operationHistory.redo() else { return }

        switch operation {
        case .swipeLeft(let card, let emailId):
            // Redo delete: remove card and delete email again
            if let index = viewModel.cards.firstIndex(where: { $0.id == card.id }) {
                viewModel.cards.remove(at: index)
            }
            viewModel.deleteEmail(emailId: emailId)
            eventService.lastSuccessMessage = "Email deleted"

            // Clear message after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                eventService.lastSuccessMessage = nil
            }

        case .swipeRight(let card, _, _):
            // Redo save: add to saved section and remove from deck
            savedCards.append(card)
            if let index = viewModel.cards.firstIndex(where: { $0.id == card.id }) {
                viewModel.cards.remove(at: index)
            }
            eventService.lastSuccessMessage = "Re-saved"

            // Clear message after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                eventService.lastSuccessMessage = nil
            }
        }
    }

    // MARK: - Swipe Handlers

    private func handleSwipeRight() {
        let card = viewModel.cards[viewModel.currentIndex]

        // Check if this email has subcards (events or todos)
        if card.hasSubcards {
            // Enter subcard mode
            withAnimation {
                viewModel.isInSubcardMode = true
                viewModel.currentSubcardIndex = 0
                offset = .zero
            }
        } else {
            // No subcards, just save and move to next
            savedCards.append(card)
            operationHistory.recordOperation(.swipeRight(card: card, addedToCalendar: false, addedToReminders: false))

            withAnimation {
                offset = CGSize(width: 500, height: 0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                viewModel.removeCurrentCard()
                offset = .zero
            }
        }
    }

    private func handleSwipeLeft() {
        let card = viewModel.cards[viewModel.currentIndex]

        // Record operation for undo/redo
        operationHistory.recordOperation(.swipeLeft(card: card, emailId: card.email.id))

        // Delete email from Outlook via Graph API
        viewModel.deleteEmail(emailId: card.email.id)

        withAnimation {
            offset = CGSize(width: -500, height: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            viewModel.removeCurrentCard()
            offset = .zero
        }
    }

    // MARK: - Subcard Handlers

    private func handleAddToCalendar(_ event: Event) {
        Task {
            // Parse start date (required for events)
            guard let startDateStr = event.start_date,
                  let start = ISO8601DateFormatter().date(from: startDateStr) else {
                await MainActor.run {
                    eventService.lastError = NSError(domain: "Invalid event start date", code: -1)
                }
                return
            }

            // Parse end date or default to 1 hour after start
            let end: Date
            if let endDateStr = event.end_date,
               let parsedEnd = ISO8601DateFormatter().date(from: endDateStr) {
                end = parsedEnd
            } else {
                // Default: 1 hour duration
                end = start.addingTimeInterval(3600)
            }

            _ = await eventService.addCalendarEvent(
                title: event.title,
                startDate: start,
                endDate: end,
                location: event.location,
                notes: event.notes,
                isAllDay: event.all_day
            )

            await MainActor.run {
                advanceSubcard()
            }
        }
    }

    private func handleAddToReminder(_ todo: Todo) {
        Task {
            let due = ISO8601DateFormatter().date(from: todo.due_date ?? "")
            _ = await eventService.addReminder(
                title: todo.title,
                notes: todo.notes,
                dueDate: due,
                priority: todo.priority
            )

            await MainActor.run {
                advanceSubcard()
            }
        }
    }

    private func handleSkipSubcard() {
        advanceSubcard()
    }

    private func advanceSubcard() {
        let card = viewModel.cards[viewModel.currentIndex]

        // Check if there are more subcards
        if viewModel.currentSubcardIndex < card.totalSubcards - 1 {
            // Move to next subcard
            withAnimation {
                viewModel.currentSubcardIndex += 1
            }
        } else {
            // All subcards processed - save email and move to next
            savedCards.append(card)
            operationHistory.recordOperation(.swipeRight(card: card, addedToCalendar: true, addedToReminders: true))

            // Exit subcard mode and move to next email
            viewModel.isInSubcardMode = false
            viewModel.currentSubcardIndex = 0

            withAnimation {
                offset = CGSize(width: 500, height: 0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                viewModel.removeCurrentCard()
                offset = .zero
            }
        }
    }
}

#Preview {
    ContentView()
}
