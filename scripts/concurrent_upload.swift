import Foundation

func runCurl() async throws {
    let url = URL(string: "http://127.0.0.1:8080/")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")

    let fileURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads/100MB.bin")
    let data = try Data(contentsOf: fileURL)

    let (_, response) = try await URLSession.shared.upload(for: request, from: data)

    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode) else {
        throw NSError(domain: "HTTPError", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTTP request failed"])
    }
    // print(".", terminator: "")
}

// Function to run all curl requests concurrently
func runAllRequests() async {
    await withTaskGroup(of: Void.self) { group in
        for i in 1...50 {
            group.addTask {
                do {
                    try await runCurl()
                    print(i, terminator: " |")
                } catch {
                    print("Error in curl request: \(error)")
                }
            }
        }
    }

    print("All curl requests completed.")
}

await runAllRequests()

// Keep the program running
//RunLoop.main.run()
