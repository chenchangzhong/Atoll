import XCTest
@testable import LocalSendProtocol

final class RequestHeadTests: XCTestCase {
    private func head(_ text: String) -> LocalSendProtocol.RequestHead? {
        LocalSendProtocol.RequestHead(data: Data(text.utf8))
    }

    func testParsesMethodPathQueryAndLength() {
        let parsed = head("""
        POST /api/localsend/v2/upload?sessionId=abc&fileId=f1&token=1234 HTTP/1.1\r
        Host: mac.local\r
        Content-Length: 2048\r
        \r

        """)
        XCTAssertEqual(parsed?.method, "POST")
        XCTAssertEqual(parsed?.path, "/api/localsend/v2/upload")
        XCTAssertEqual(parsed?.query["sessionId"], "abc")
        XCTAssertEqual(parsed?.query["fileId"], "f1")
        XCTAssertEqual(parsed?.query["token"], "1234")
        XCTAssertEqual(parsed?.contentLength, 2048)
        XCTAssertEqual(parsed?.isChunked, false)
    }

    func testLowercaseHeadersAndPercentEncoding() {
        let parsed = head("""
        post /api/localsend/v2/prepare-upload?alias=%E9%92%9F HTTP/1.1\r
        content-length: 7\r
        transfer-encoding: chunked\r
        \r

        """)
        XCTAssertEqual(parsed?.method, "POST", "the method is normalised")
        XCTAssertEqual(parsed?.query["alias"], "钟")
        XCTAssertEqual(parsed?.contentLength, 7)
        XCTAssertEqual(parsed?.isChunked, true, "a phone streams its body")
    }

    func testChunkedRequestWithoutLength() {
        let parsed = head("POST /api/localsend/v2/upload?fileId=f1 HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
        XCTAssertNil(parsed?.contentLength)
        XCTAssertEqual(parsed?.isChunked, true)
        XCTAssertEqual(parsed?.query.count, 1)
    }

    func testRejectsGarbage() {
        XCTAssertNil(head(""))
        XCTAssertNil(head("\r\n\r\n"))
        XCTAssertNil(head("GET\r\n\r\n"), "a request line needs a target")
    }
}

final class ChunkSizeTests: XCTestCase {
    func testParsesHexWithExtensions() throws {
        XCTAssertEqual(try LocalSendProtocol.chunkSize(fromLine: "400"), 1024)
        XCTAssertEqual(try LocalSendProtocol.chunkSize(fromLine: "1a3f"), 6719)
        XCTAssertEqual(try LocalSendProtocol.chunkSize(fromLine: "1a3f;ext=value"), 6719)
        XCTAssertEqual(try LocalSendProtocol.chunkSize(fromLine: " 10 "), 16)
        XCTAssertEqual(try LocalSendProtocol.chunkSize(fromLine: "0"), 0)
    }

    func testRejectsMalformedLines() {
        for line in ["", "zz", "-5", "0x10", "12 34"] {
            XCTAssertThrowsError(try LocalSendProtocol.chunkSize(fromLine: line), "line \(line.debugDescription)") { error in
                XCTAssertEqual(error as? LocalSendProtocolError, .malformedChunk)
            }
        }
    }
}

final class ChunkBoundTests: XCTestCase {
    func testAccumulatesWithinTheLimit() throws {
        let maximum = 1_048_576
        var delivered = 0
        delivered = try LocalSendProtocol.acceptingChunkSize(1024, delivered: delivered, maximum: maximum)
        delivered = try LocalSendProtocol.acceptingChunkSize(2048, delivered: delivered, maximum: maximum)
        XCTAssertEqual(delivered, 3072)
    }

    func testAcceptsExactlyTheLimitAndRejectsOnePastIt() throws {
        let maximum = 4096
        let atLimit = try LocalSendProtocol.acceptingChunkSize(4096, delivered: 0, maximum: maximum)
        XCTAssertEqual(atLimit, maximum)
        XCTAssertThrowsError(try LocalSendProtocol.acceptingChunkSize(1, delivered: atLimit, maximum: maximum)) { error in
            XCTAssertEqual(error as? LocalSendProtocolError, .tooLarge)
        }
    }

    /// The remote kill found in review: a peer that announced a chunk of
    /// `Int.max` used to overflow `delivered + size` and trap the process.
    func testHugeChunkSizeCannotOverflow() {
        XCTAssertThrowsError(try LocalSendProtocol.acceptingChunkSize(Int.max, delivered: 1024, maximum: 1_048_576)) { error in
            XCTAssertEqual(error as? LocalSendProtocolError, .tooLarge)
        }
        // With nothing accumulated the arithmetic is exact rather than trapping;
        // the transfer is kept bounded by the caller (the service clamps the
        // maximum to 8 GiB) and by the decoder reading a chunk in 256 KiB pieces,
        // so a huge announced chunk cannot reserve unbounded memory here.
        XCTAssertEqual(try? LocalSendProtocol.acceptingChunkSize(Int.max, delivered: 0, maximum: Int.max), Int.max)
    }
}

final class FileNameTests: XCTestCase {
    func testKeepsOrdinaryNames() {
        XCTAssertEqual(LocalSendProtocol.sanitizedFileName("IMG_1234.jpg"), "IMG_1234.jpg")
        XCTAssertEqual(LocalSendProtocol.sanitizedFileName("  spaced.txt  "), "spaced.txt")
        XCTAssertEqual(LocalSendProtocol.sanitizedFileName("报告 2026.pdf"), "报告 2026.pdf")
    }

    func testStripsPathComponents() {
        XCTAssertEqual(LocalSendProtocol.sanitizedFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(LocalSendProtocol.sanitizedFileName("/tmp/photo.jpg"), "photo.jpg")
        XCTAssertEqual(LocalSendProtocol.sanitizedFileName("a/b:c.txt"), "b_c.txt")
    }

    func testNeverYieldsAnEmptyOrDotName() {
        for raw in ["", ".", "..", "   ", "../"] {
            let name = LocalSendProtocol.sanitizedFileName(raw)
            XCTAssertFalse(name.isEmpty, raw.debugDescription)
            XCTAssertNotEqual(name, ".", raw.debugDescription)
            XCTAssertNotEqual(name, "..", raw.debugDescription)
        }
    }

    func testResultCannotEscapeTheDirectory() {
        for raw in ["../../etc/passwd", "/etc/hosts", "..\\..\\windows", "a/b", "x:y"] {
            let name = LocalSendProtocol.sanitizedFileName(raw)
            XCTAssertFalse(name.contains("/"), raw.debugDescription)
            XCTAssertFalse(name.contains(":"), raw.debugDescription)
        }
    }
}
