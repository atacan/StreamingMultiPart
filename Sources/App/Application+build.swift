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
        // let outUrl = URL(string: "https://httpbin.org/post")!
         let outUrl = URL(string: "http://127.0.0.1:8080/donothing")! // to this server
//         let outUrl = URL(string: "http://127.0.0.1:80")! // some fastapi server. see scripts/fastapi_test/main.py

        var outRequest = HTTPClientRequest.init(url: outUrl.absoluteString)
        outRequest.method = .POST
        outRequest.headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")

        let fieldName = "file"
        let filename = "100MB.bin"
        let mimeType = "octet/stream"

        var streamTask: Task<Void, Error>?
        let stream = AsyncStream<ByteBuffer> { continuation in
            streamTask = Task {
                let headerString = [
                    "--\(boundary)\r\n",
                    "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n",
                    "Content-Type: \(mimeType)\r\n\r\n"
                ].joined()

                let headerBuffer = ByteBuffer(string: headerString)
                continuation.yield(headerBuffer)

                logger.log(level: .info, "looping request.body...")
                for try await buffer in request.body {
                    // print("🔹", terminator: "")
                    continuation.yield(buffer)
                }
                logger.log(level: .info, "\nfinished looping request.body")

                let footerBuffer = ByteBuffer(string: "\r\n--\(boundary)--\r\n")
                continuation.yield(footerBuffer)

                logger.log(level: .info, "continuation.finish()...")
                continuation.finish()
            }

            continuation.onTermination = { _ in
                logger.log(level: .info, "continuation.onTermination")
                // streamTask?.cancel() // 🔴 Reference to captured var 'streamTask' in concurrently-executing code
            }
        }

        outRequest.body = .stream(stream, length: .unknown)

        logger.log(level: .info, "starting request")
        let response = try await httpClient.execute(outRequest, timeout: .seconds(160))
        streamTask?.cancel()
        streamTask = nil
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

    struct AsyncIterator: AsyncIteratorProtocol {

        func next() async throws -> ByteBuffer? {

        }

    }

    func makeAsyncIterator() -> AsyncIterator {
        .init()
    }
}
