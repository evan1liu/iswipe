import SwiftUI
import Combine

// 1. The Data Model matches the JSON from our Python Backend
struct Email: Identifiable, Codable {
    // API returns: from_addr, subject, date, preview
    // We can use UUID() for id since the API doesn't return a guaranteed simple ID, or use subject+date as a hack.
    // Ideally the API should return an ID, but let's make it Identifiable locally.
    let id = UUID()
    let from_addr: String
    let subject: String
    let date: String
    let preview: String
    
    enum CodingKeys: String, CodingKey {
        case from_addr
        case subject
        case date
        case preview
    }
}

// 2. The ViewModel to fetch data
class EmailViewModel: ObservableObject {
    @Published var emails: [Email] = []
    @Published var currentIndex: Int = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var useTestEmails = false

    func fetchEmails() {
        let endpoint = useTestEmails ? "/test-emails" : "/emails"
        guard let url = URL(string: "http://127.0.0.1:8000\(endpoint)") else { return }
        
        isLoading = true
        errorMessage = nil
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                self.isLoading = false
                if let error = error {
                    self.errorMessage = "Error: \(error.localizedDescription)\nMake sure Python backend is running!"
                    return
                }
                
                guard let data = data else { return }
                
                do {
                    let decodedEmails = try JSONDecoder().decode([Email].self, from: data)
                    self.emails = decodedEmails
                } catch {
                    self.errorMessage = "Failed to decode: \(error.localizedDescription)"
                }
            }
        }.resume()
    }
    
    func nextEmail() {
        if currentIndex < emails.count - 1 {
            currentIndex += 1
        }
    }
    
    func previousEmail() {
        if currentIndex > 0 {
            currentIndex -= 1
        }
    }
}

// 3. The View
struct ContentView: View {
    @StateObject var viewModel = EmailViewModel()
    @StateObject var eventService = IntegratedEventService()

    var body: some View {
        VStack {
            // Toggle between real and test emails
            HStack {
                Text(viewModel.useTestEmails ? "Test Mode" : "Real Emails")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle("Use Test Emails", isOn: $viewModel.useTestEmails)
                    .labelsHidden()
                    .onChange(of: viewModel.useTestEmails) { _ in
                        viewModel.fetchEmails()
                    }
            }
            .padding(.horizontal)
            .padding(.top, 10)

            if viewModel.isLoading {
                ProgressView("Loading emails from Python...")
            } else if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding()
                Button("Retry") {
                    viewModel.fetchEmails()
                }
            } else if viewModel.emails.isEmpty {
                Text("No emails found.")
                Button("Load Emails") {
                    viewModel.fetchEmails()
                }
            } else {
                // Card View
                let email = viewModel.emails[viewModel.currentIndex]
                let parsedEvent = EventParser.parseEvent(from: email.preview)

                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(email.subject)
                            .font(.title)
                            .bold()
                        Spacer()
                        // Badge indicating email type
                        if parsedEvent.isValid {
                            Text("Event")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.2))
                                .foregroundColor(.blue)
                                .cornerRadius(8)
                        } else {
                            Text("Task")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.2))
                                .foregroundColor(.orange)
                                .cornerRadius(8)
                        }
                    }

                    Text("From: \(email.from_addr)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text(email.date)
                        .font(.caption)
                        .foregroundColor(.gray)

                    // Show parsed event info if available
                    if parsedEvent.isValid, let start = parsedEvent.startDate, let end = parsedEvent.endDate {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.clock")
                                .foregroundColor(.blue)
                            Text("\(formatDateTime(start)) - \(formatDateTime(end))")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }

                        if let location = parsedEvent.location {
                            HStack(spacing: 4) {
                                Image(systemName: "location.fill")
                                    .foregroundColor(.blue)
                                Text(location)
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }
                    }

                    Divider()
                    
                    Text(email.preview)
                        .font(.body)
                        .padding(.top)
                    
                    Spacer()
                }
                .padding()
                .background(Color.white)
                .cornerRadius(12)
                .shadow(radius: 5)
                .padding()
                
                // Action Buttons
                VStack(spacing: 15) {
                    // Suggestion text
                    if parsedEvent.isValid {
                        Text("This email contains event details - add to Calendar")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .italic()
                    } else {
                        Text("No event details found - add as Reminder")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .italic()
                    }

                    HStack(spacing: 20) {
                        // Add to Calendar Button
                        Button(action: {
                            Task {
                                await addToCalendar(email)
                            }
                        }) {
                            HStack {
                                Image(systemName: "calendar.badge.plus")
                                Text("Add to Calendar")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .accessibilityLabel("Add to Calendar")

                        // Add Reminder Button
                        Button(action: {
                            Task {
                                await addReminder(email)
                            }
                        }) {
                            HStack {
                                Image(systemName: "bell.badge.fill")
                                Text("Add Reminder")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .accessibilityLabel("Add Reminder")
                    }
                    .padding(.horizontal)

                    // Show success or error messages
                    if let successMessage = eventService.lastSuccessMessage {
                        Text(successMessage)
                            .foregroundColor(.green)
                            .font(.caption)
                            .padding(.horizontal)
                    }

                    if let error = eventService.lastError {
                        Text(error.localizedDescription)
                            .foregroundColor(.red)
                            .font(.caption)
                            .padding(.horizontal)
                    }
                }

                // Navigation Buttons
                HStack(spacing: 40) {
                    Button(action: {
                        withAnimation { viewModel.previousEmail() }
                    }) {
                        Image(systemName: "arrow.left.circle.fill")
                            .resizable()
                            .frame(width: 50, height: 50)
                            .foregroundColor(viewModel.currentIndex > 0 ? .blue : .gray)
                    }
                    .disabled(viewModel.currentIndex == 0)

                    Text("\(viewModel.currentIndex + 1) / \(viewModel.emails.count)")
                        .font(.headline)

                    Button(action: {
                        withAnimation { viewModel.nextEmail() }
                    }) {
                        Image(systemName: "arrow.right.circle.fill")
                            .resizable()
                            .frame(width: 50, height: 50)
                            .foregroundColor(viewModel.currentIndex < viewModel.emails.count - 1 ? .blue : .gray)
                    }
                    .disabled(viewModel.currentIndex == viewModel.emails.count - 1)
                }
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            viewModel.fetchEmails()
        }
        .background(Color(UIColor.systemGroupedBackground))
    }

    // MARK: - Helper Functions

    private func addToCalendar(_ email: Email) async {
        // Parse email to extract event details
        let parsedEvent = EventParser.parseEvent(from: email.preview)

        let title = email.subject
        let startDate: Date
        let endDate: Date
        let location: String?

        // Use parsed dates if available, otherwise use defaults
        if let parsedStart = parsedEvent.startDate, let parsedEnd = parsedEvent.endDate {
            startDate = parsedStart
            endDate = parsedEnd
            location = parsedEvent.location
        } else {
            // Fallback to default times (1 hour from now, duration 1 hour)
            startDate = Date().addingTimeInterval(3600)
            endDate = startDate.addingTimeInterval(3600)
            location = nil
        }

        let _ = await eventService.addCalendarEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            notes: email.preview,
            isAllDay: false
        )
    }

    private func addReminder(_ email: Email) async {
        // Create reminder from email
        let title = email.subject
        let dueDate = Date().addingTimeInterval(86400) // 24 hours from now

        let _ = await eventService.addReminder(
            title: title,
            notes: email.preview,
            dueDate: dueDate,
            priority: 5
        )
    }

    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

