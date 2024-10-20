import AsyncHTTPClient
import MultipartKit
import Foundation
import Hummingbird
import Logging
import NIOCore
import NIOPosix
import ServiceLifecycle

func buildApplication(configuration: ApplicationConfiguration) -> some ApplicationProtocol {
    let eventLoopGroup = MultiThreadedEventLoopGroup.singleton
    let httpClient = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup))

    let router = Router()
    // router.middlewares.add(LogRequestsMiddleware(.info))

    router.post("/donothing") { _, _ in
        try await Task.sleep(nanoseconds: NSEC_PER_SEC)
        return "Hello"
    }

    MyController(httpClient: httpClient).addRoutes(to: router)

    var app = Application(
        router: router,
        configuration: configuration
    )
    app.addServices(HTTPClientService(client: httpClient))
    return app
}

struct MyController {
    let httpClient: HTTPClient

    func addRoutes(to router: some RouterMethods<some RequestContext>) {
        router.post("/", use: self.streamRequestBodyToMultiPartRequest)
        router.post("/add", use: self.streamRequestBodyToMultiPartRequestWithAdditionalFields)
    }

    @Sendable
    func streamRequestBodyToMultiPartRequest(request: Request, context: some RequestContext) async throws -> String {
        logger.log(level: .info, "Request received")

        let boundary = UUID().uuidString
//         let outUrl = "http://127.0.0.1:8080/donothing" // to this server
         let outUrl = "http://127.0.0.1:80" // some fastapi server. see scripts/fastapi_test/main.py

        var outRequest = HTTPClientRequest(url: outUrl)
        outRequest.method = .POST
        outRequest.headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")

        let requestCopy = request
        let multiPartSequence = MultiPartFileBodyFromSequence(
            base: requestCopy.body,
            boundary: boundary,
            fieldName: "file",
            filename: "100MB.bin",
            mimeType: "octet/stream"
        )

        outRequest.body = .stream(multiPartSequence, length: .unknown)

        logger.log(level: .info, "starting request")
        let response = try await httpClient.execute(outRequest, timeout: .seconds(160))
        for try await _ in response.body {}
        logger.log(level: .info, "finished request")

        return "Done"
    }

    @Sendable func streamRequestBodyToMultiPartRequestWithAdditionalFields(request: Request, context: some RequestContext) async throws -> String {
        logger.log(level: .info, "Request received")

        let boundary = UUID().uuidString
        let outUrl = "https://httpbin.org/post"

        var outRequest = HTTPClientRequest(url: outUrl)
        outRequest.method = .POST
        outRequest.headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")

        let multiPartSequence = MultiPartRequestBodySequence(
            base: request.body,
            boundary: boundary,
            fieldName: "file",
            filename: "240432.jpg",
            mimeType: "image/jpeg",
            additionalFields: FormFields(name: "name surname", email: "ed@ex.com")
        )

        outRequest.body = .stream(multiPartSequence, length: .unknown)

        let response = try await httpClient.execute(outRequest, timeout: .seconds(160))

        let responseBody = try await response.body.collect(upTo: 10 * 1024 * 1024)
        return try jsonObjectString(responseBody)
    }
}

struct HTTPClientService: Service {
    let client: HTTPClient

    func run() async throws {
        try? await gracefulShutdown()
        try await self.client.shutdown()
    }
}

let logger = Logger(label: "App")

struct MultiPartFileBodyFromSequence<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable where Base.Element == ByteBuffer {
    typealias Element = ByteBuffer

    private let base: Base
    private let boundary: String
    private let fieldName: String
    private let filename: String
    private let mimeType: String

    init(base: Base, boundary: String, fieldName: String, filename: String, mimeType: String) {
        self.base = base
        self.boundary = boundary
        self.fieldName = fieldName
        self.filename = filename
        self.mimeType = mimeType
    }

    class AsyncIterator: AsyncIteratorProtocol {
        private var baseIterator: Base.AsyncIterator
        private let sequence: MultiPartFileBodyFromSequence

        private var headerSent = false
        private var footerSent = false

        init(sequence: MultiPartFileBodyFromSequence) {
            self.sequence = sequence
            self.baseIterator = sequence.base.makeAsyncIterator()
        }

        func next() async throws -> ByteBuffer? {
            if !headerSent {
                let headerString = [
                    "--\(sequence.boundary)\r\n",
                    "Content-Disposition: form-data; name=\"\(sequence.fieldName)\"; filename=\"\(sequence.filename)\"\r\n",
                    "Content-Type: \(sequence.mimeType)\r\n\r\n"
                ].joined()
                logger.log(level: .info, "\(sequence.boundary) headerSent")
                headerSent = true
                return ByteBuffer(string: headerString)
            }

            if let buffer = try await baseIterator.next() {
                print(".", terminator: "")
                return buffer
            }

            if !footerSent {
                logger.log(level: .info, "\(sequence.boundary) footerSent")
                footerSent = true
                return ByteBuffer(string: "\r\n--\(sequence.boundary)--\r\n")
            }

            return nil
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(sequence: self)
    }
}

func jsonObjectString(_ data: ByteBuffer) throws -> String {
    let json = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
    // pretty print the json object
    let jsonData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
    let jsonPretty = String(data: jsonData, encoding: .utf8)

//    @Dependency(\.logger) var logger
    return "\(jsonPretty ?? "Could not pretty print JSON")"
}

struct MultiPartRequestBodySequence<Base: AsyncSequence & Sendable, T: Codable & Sendable>: AsyncSequence, Sendable where Base.Element == ByteBuffer {
    typealias Element = ByteBuffer

    private let base: Base
    private let boundary: String
    private let fieldName: String
    private let filename: String
    private let mimeType: String
    private let additionalFields: T

    init(base: Base, boundary: String, fieldName: String, filename: String, mimeType: String, additionalFields: T) {
        self.base = base
        self.boundary = boundary
        self.fieldName = fieldName
        self.filename = filename
        self.mimeType = mimeType
        self.additionalFields = additionalFields
    }

    class AsyncIterator: AsyncIteratorProtocol {
        private var baseIterator: Base.AsyncIterator
        private let sequence: MultiPartRequestBodySequence

        private var state: IteratorState = .startingCase()

        init(sequence: MultiPartRequestBodySequence) {
            self.sequence = sequence
            self.baseIterator = sequence.base.makeAsyncIterator()
        }

        func next() async throws -> ByteBuffer? {
            switch state {
            case .additionalFields:
                // "--abc123\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nEd\r\n--abc123\r\nContent-Disposition: form-data; name=\"email\"\r\n\r\ned@example.com\r\n--abc123--\r\n"
                let encoder = FormDataEncoder()
                let encodedFields = try encoder.encode(sequence.additionalFields, boundary: sequence.boundary)
                logger.log(level: .info, "\(sequence.boundary) additionalFieldsSent")
                state.nextCase()
                return ByteBuffer(string: encodedFields)

            case .fileHeader:
                let headerString = [
                    "--\(sequence.boundary)\r\n",
                    "Content-Disposition: form-data; name=\"\(sequence.fieldName)\"; filename=\"\(sequence.filename)\"\r\n",
                    "Content-Type: \(sequence.mimeType)\r\n\r\n"
                ].joined()
                logger.log(level: .info, "\(sequence.boundary) headerSent")
                state.nextCase()
                return ByteBuffer(string: headerString)

            case .fileContent:
                if let buffer = try await baseIterator.next() {
                    print(".", terminator: "")
                    return buffer
                }
                state.nextCase()
                print("\nfileContent done")
                return try await next()

            case .fileFooter:
                logger.log(level: .info, "\(sequence.boundary) footerSent")
                state.nextCase()
                return ByteBuffer(string: "\r\n")

            case .finished:
                logger.log(level: .info, "\(sequence.boundary) finished")
                return nil
            }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(sequence: self)
    }

    private enum IteratorState {
        case additionalFields
        case fileHeader
        case fileContent
        case fileFooter
        case finished

        mutating func nextCase() {
            switch self {
            case .fileHeader: self = .fileContent
            case .fileContent: self = .fileFooter
            case .fileFooter: self = .additionalFields
            case .additionalFields: self = .finished
            case .finished: break // Already at the end
            }
        }
        
        static func startingCase() -> IteratorState {
            .fileHeader
        }
    }

}

struct FormFields: Codable {
    var name: String
    var email: String
}
