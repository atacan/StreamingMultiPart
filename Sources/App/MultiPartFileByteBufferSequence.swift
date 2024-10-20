import NIOCore
import MultipartKit

extension FormDataDecoder {
    public func decodeFileData<S: AsyncSequence & Sendable>(
        from sequence: S,
        boundary: String,
        fieldName: String
    ) -> FileByteBufferSequenceFromMultiPart<S> where S.Element == ByteBuffer {
        FileByteBufferSequenceFromMultiPart(base: sequence, boundary: boundary, fieldName: fieldName)
    }
}

public struct FileByteBufferSequenceFromMultiPart<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable where Base.Element == ByteBuffer {
    public typealias Element = ByteBuffer

    let base: Base
    let boundary: String
    let fieldName: String

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(baseIterator: base.makeAsyncIterator(), boundary: boundary, fieldName: fieldName)
    }

    public class AsyncIterator: AsyncIteratorProtocol {
        var baseIterator: Base.AsyncIterator
        let parser: MultipartParser
        var isInTargetField: Bool
        var isInFileData: Bool
        var buffer: ByteBuffer
        var hasStartedFileContent: Bool

        init(baseIterator: Base.AsyncIterator, boundary: String, fieldName: String) {
            self.baseIterator = baseIterator
            self.parser = MultipartParser(boundary: boundary)
            self.isInTargetField = false
            self.isInFileData = false
            self.buffer = ByteBuffer()
            self.hasStartedFileContent = false

            self.parser.onHeader = { [weak self] field, value in
                if field.lowercased() == "content-disposition" {
                    self?.isInTargetField = value.contains("name=\"\(fieldName)\"")
                    self?.hasStartedFileContent = false
                }
            }

            self.parser.onBody = { [weak self] new in
                guard let self = self, self.isInTargetField else { return }
                if !self.hasStartedFileContent {
                    // Skip the first newline which separates headers from content
                    var new = new
                    if new.readableBytes > 0 && new.getInteger(at: new.readerIndex) == UInt8(ascii: "\n") {
                        new.moveReaderIndex(forwardBy: 1)
                    }
                    self.hasStartedFileContent = true
                }
                self.buffer.writeBuffer(&new)
            }

            self.parser.onPartComplete = { [weak self] in
                self?.isInTargetField = false
                self?.isInFileData = false
                self?.hasStartedFileContent = false
            }
        }

        public func next() async throws -> ByteBuffer? {
            while true {
                if !buffer.readableBytesView.isEmpty {
                    let result = buffer
                    buffer.clear()
                    return result
                }

                guard let nextChunk = try await baseIterator.next() else {
                    return nil
                }

                try parser.execute(nextChunk)

                if isInTargetField && !isInFileData {
                    isInFileData = true
                }

                if !isInFileData {
                    buffer.clear()
                }
            }
        }
    }
}
