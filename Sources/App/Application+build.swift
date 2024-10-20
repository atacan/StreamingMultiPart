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
        router.post("/new", use: self.newStreamRequestBodyToMultiPartRequest)
        router.post("/add", use: self.streamRequestBodyToMultiPartRequestWithAdditionalFields)
        router.post("/multifileextract", use: self.streamFileFromMultiparRequestBody)
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
            multipartFile: .init(
                fieldName: "file",
                filename: "100MB.bin",
                mimeType: "octet/stream",
                content: requestCopy.body
            ),
            boundary: boundary
        )

        outRequest.body = .stream(multiPartSequence, length: .unknown)

        logger.log(level: .info, "starting request")
        let response = try await httpClient.execute(outRequest, timeout: .seconds(160))
        for try await _ in response.body {}
        logger.log(level: .info, "finished request")

        return "Done"
    }
    
    @Sendable
    func newStreamRequestBodyToMultiPartRequest(request: Request, context: some RequestContext) async throws -> String {
        logger.log(level: .info, "/new Request received")

        let boundary = UUID().uuidString
        let outUrl = "https://httpbin.org/post"
//         let outUrl = "http://127.0.0.1:8080/donothing" // to this server
//         let outUrl = "http://127.0.0.1:80" // some fastapi server. see scripts/fastapi_test/main.py

        var outRequest = HTTPClientRequest(url: outUrl)
        outRequest.method = .POST
        outRequest.headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")

        let multiPartSequence = MultiPartFileBodyFromSequence(
            multipartFile: .init(
                fieldName: "file",
                filename: "100MB.bin",
                mimeType: "octet/stream",
                content: request.body
            ),
            boundary: boundary
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
            multipartFile: .init(
                fieldName: "file",
                filename: "240432.jpg",
                mimeType: "image/jpeg",
                content: request.body
            ),
            boundary: boundary,
            additionalFields: FormFields(name: "name surname", email: "ed@ex.com")
        )

        outRequest.body = .stream(multiPartSequence, length: .unknown)

        let response = try await httpClient.execute(outRequest, timeout: .seconds(160))

        let responseBody = try await response.body.collect(upTo: 10 * 1024 * 1024)
        return try jsonObjectString(responseBody)
    }
    
    @Sendable
    func streamFileFromMultiparRequestBody(request: Request, context: some RequestContext) async throws -> String {
        logger.log(level: .info, "multifileextract Request received")
        guard let contentType = request.headers[.contentType],
              let mediaType = MediaType(from: contentType),
              let parameter = mediaType.parameter,
              parameter.name == "boundary"
        else {
            throw HTTPError(.unsupportedMediaType)
        }
        let fileBuffers = FileByteBufferSequenceFromMultiPart(base: request.body, boundary: parameter.value, fieldName: "file")
        
        let fileIO = FileIO()
        let fileURL = try FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("240432_from_HB.jpg")
        try await fileIO.writeFile(
            contents: fileBuffers,
            path: fileURL.path,
            context: context
        )
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

struct MultipartFile<Base: AsyncSequence & Sendable>: Sendable {
    let fieldName: String
    let filename: String
    let mimeType: String
    let content: Base
}

struct MultiPartFileBodyFromSequence<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable where Base.Element == ByteBuffer {
    typealias Element = ByteBuffer

    private let multipartFile: MultipartFile<Base>
    private let boundary: String

    init(multipartFile: MultipartFile<Base>, boundary: String) {
        self.multipartFile = multipartFile
        self.boundary = boundary
    }

    class AsyncIterator: AsyncIteratorProtocol {
        private let sequence: MultiPartFileBodyFromSequence
        private var baseIterator: Base.AsyncIterator

        private var headerSent = false
        private var footerSent = false

        init(sequence: MultiPartFileBodyFromSequence) {
            self.sequence = sequence
            self.baseIterator = sequence.multipartFile.content.makeAsyncIterator()
        }

        func next() async throws -> ByteBuffer? {
            if !headerSent {
                let headerString = [
                    "--\(sequence.boundary)\r\n",
                    "Content-Disposition: form-data; name=\"\(sequence.multipartFile.fieldName)\"; filename=\"\(sequence.multipartFile.filename)\"\r\n",
                    "Content-Type: \(sequence.multipartFile.mimeType)\r\n\r\n"
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

    return "\(jsonPretty ?? "Could not pretty print JSON")"
}

struct MultiPartRequestBodySequence<Base: AsyncSequence & Sendable, T: Codable & Sendable>: AsyncSequence, Sendable where Base.Element == ByteBuffer {
    typealias Element = ByteBuffer

    private let multipartFile: MultipartFile<Base>
    private let boundary: String
    private let additionalFields: T

    init(multipartFile: MultipartFile<Base>, boundary: String, additionalFields: T) {
        self.multipartFile = multipartFile
        self.boundary = boundary
        self.additionalFields = additionalFields
    }

    class AsyncIterator: AsyncIteratorProtocol {
        private var baseIterator: Base.AsyncIterator
        private let sequence: MultiPartRequestBodySequence

        private var state: IteratorState = .startingCase()

        init(sequence: MultiPartRequestBodySequence) {
            self.sequence = sequence
            self.baseIterator = sequence.multipartFile.content.makeAsyncIterator()
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
                    "Content-Disposition: form-data; name=\"\(sequence.multipartFile.fieldName)\"; filename=\"\(sequence.multipartFile.filename)\"\r\n",
                    "Content-Type: \(sequence.multipartFile.mimeType)\r\n\r\n"
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
