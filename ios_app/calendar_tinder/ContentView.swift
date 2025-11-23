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

// Represents a single "card" in the deck
enum CardType: Identifiable {
    case todo(Todo)
    case event(Event)
    
    var id: String {
        switch self {
        case .todo(let t): return "todo-\(t.id)"
        case .event(let e): return "event-\(e.id)"
        }
    }
}

struct Card: Identifiable {
    let id = UUID()
    let emailId: String
    let emailSubject: String
    let type: CardType
    // We keep a reference to the full email mainly for the "original" view
    let email: Email
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

class EmailViewModel: ObservableObject {
    @Published var cards: [Card] = []
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
    
    enum SlideDirection {
        case forward
        case backward
    }
    
    // IMPORTANT: Change this to your computer's local IP address when testing on a real device
    // To find your IP: Open Terminal and run: ifconfig | grep "inet " | grep -v 127.0.0.1
    // Use 127.0.0.1 for simulator, your local IP (e.g., 192.168.1.x) for real device
    private let baseURL = "http://10.141.0.236:8000"  // Your computer's IP for real device
    
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
        var newCards: [Card] = []
        
        for email in emails {
            // 1. Add Event Cards
            for event in email.events {
                newCards.append(Card(emailId: email.id, emailSubject: email.subject, type: .event(event), email: email))
            }
            
            // 2. Add Todo Cards
            for todo in email.todos {
                newCards.append(Card(emailId: email.id, emailSubject: email.subject, type: .todo(todo), email: email))
            }
        }
        
        self.cards = newCards
        self.currentIndex = 0
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
}

// --- VIEWS ---

struct CardView: View {
    let card: Card
    @State private var showingOriginalEmail = false
    
    var body: some View {
        VStack {
            switch card.type {
            case .event(let event):
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
                
            case .todo(let todo):
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(20)
        .shadow(color: Color.black.opacity(0.2), radius: 10)
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
}

struct ContentView: View {
    @StateObject var viewModel = EmailViewModel()
    @StateObject var eventService = IntegratedEventService()
    
    // Gesture State
    @State private var offset = CGSize.zero
    
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
            Text("Welcome to Email AI")
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
        VStack {
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
            } else if viewModel.cards.isEmpty {
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
            } else {
                // Main Interface
                VStack(spacing: 0) {
                    // Top Header: Email Subject
                    // We display the subject of the *current card*
                    Text(viewModel.cards[viewModel.currentIndex].emailSubject)
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
                            CardView(card: viewModel.cards[viewModel.currentIndex + 1])
                                .scaleEffect(0.95)
                                .offset(y: 10)
                        }
                        
                        // Current Card
                        CardView(card: viewModel.cards[viewModel.currentIndex])
                            .offset(x: offset.width, y: 0)
                            .rotationEffect(.degrees(Double(offset.width / 20)))
                            .gesture(
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
                    Text("\(viewModel.currentIndex + 1) / \(viewModel.cards.count)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 30)
                }
            }
        }
        .background(Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.all))
    }
    
    // MARK: - Swipe Handlers
    
    private func handleSwipeRight() {
        let card = viewModel.cards[viewModel.currentIndex]
        let currentViewModel = viewModel // Capture reference
        
        Task {
            switch card.type {
            case .event(let event):
                // Parse start date (required for events)
                guard let startDateStr = event.start_date,
                      let start = ISO8601DateFormatter().date(from: startDateStr) else {
                    // Should not happen if prompt is followed correctly
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
                
            case .todo(let todo):
                let due = ISO8601DateFormatter().date(from: todo.due_date ?? "")
                _ = await eventService.addReminder(
                    title: todo.title,
                    notes: todo.notes,
                    dueDate: due,
                    priority: todo.priority
                )
            }
            
            await MainActor.run { [weak currentViewModel] in
                guard let vm = currentViewModel else { return }
                withAnimation {
                    self.offset = CGSize(width: 500, height: 0)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak vm] in
                    vm?.removeCurrentCard()
                    self.offset = .zero
                }
            }
        }
    }
    
    private func handleSwipeLeft() {
        let currentViewModel = viewModel // Capture reference
        
        withAnimation {
            offset = CGSize(width: -500, height: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak currentViewModel] in
            currentViewModel?.removeCurrentCard()
            self.offset = .zero
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}


#Preview {
    ContentView()
}
