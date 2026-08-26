import Foundation

@main
struct GzipCodecCheck {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { throw CheckError.arguments }
        let plain = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let pythonGzip = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        guard GzipCodec.decompress(pythonGzip) == plain else { throw CheckError.decompress }
        guard let compressed = GzipCodec.compress(plain) else { throw CheckError.compress }
        try compressed.write(to: URL(fileURLWithPath: arguments[3]))
        print("gzip codec checks passed")
    }

    enum CheckError: Error { case arguments, compress, decompress }
}
