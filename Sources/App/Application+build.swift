import AsyncHTTPClient
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
    }

    @Sendable
    func streamRequestBodyToMultiPartRequest(request: Request, context: some RequestContext) async throws -> String {
        logger.log(level: .info, "Request received")

        let boundary = UUID().uuidString
        // let outUrl = "https://httpbin.org/post"
//         let outUrl = "http://127.0.0.1:8080/donothing" // to this server
         let outUrl = "http://127.0.0.1:80" // some fastapi server. see scripts/fastapi_test/main.py

        var outRequest = HTTPClientRequest(url: outUrl)
        outRequest.method = .POST
        outRequest.headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")

        let requestCopy = request
        let multiPartSequence = MultiPartRequestBodySequence(
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
}

struct HTTPClientService: Service {
    let client: HTTPClient

    func run() async throws {
        try? await gracefulShutdown()
        try await self.client.shutdown()
    }
}

let logger = Logger(label: "App")

struct MultiPartRequestBodySequence<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable where Base.Element == ByteBuffer {
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
        private let sequence: MultiPartRequestBodySequence
        
        private var headerSent = false
        private var footerSent = false

        init(sequence: MultiPartRequestBodySequence) {
            self.sequence = sequence
            self.baseIterator = sequence.base.makeAsyncIterator()
        }

        func next() async throws -> ByteBuffer? {
            if !headerSent {
                headerSent = true
                let headerString = [
                    "--\(sequence.boundary)\r\n",
                    "Content-Disposition: form-data; name=\"\(sequence.fieldName)\"; filename=\"\(sequence.filename)\"\r\n",
                    "Content-Type: \(sequence.mimeType)\r\n\r\n"
                ].joined()
                logger.log(level: .info, "\(sequence.boundary) headerSent")
                return ByteBuffer(string: headerString)
            }

            if let buffer = try await baseIterator.next() {
                // logger.log(level: .info, "baseIterator.next")
                return buffer
            }

            if !footerSent {
                footerSent = true
                logger.log(level: .info, "\(sequence.boundary) footerSent")
                return ByteBuffer(string: "\r\n--\(sequence.boundary)--\r\n")
            }

            return nil
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(sequence: self)
    }
}
