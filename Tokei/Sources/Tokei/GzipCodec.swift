import Foundation
import Compression

/// 标准 gzip（RFC 1952）编解码器，用于同步快照上传前的压缩。
///
/// 为什么要自己拼容器：Apple 的 Compression 框架里 `COMPRESSION_ZLIB` 名字有误导性，
/// 它实际产出的是 **raw DEFLATE（RFC 1951）**，既没有 zlib 头也没有 gzip 头。
/// 而对端（Python 的 `gzip` 标准库、各家网盘的解压工具）认的是完整 gzip 格式：
///
///     10 字节固定头 + 可选字段 + deflate 数据 + CRC32(4B, 小端) + 原始长度(4B, 小端)
///
/// 所以这里用 Compression 框架做 deflate 内核，头尾由本文件自己拼装和校验，
/// 保证与 `gzip.compress()` / `gzip.decompress()` 双向互通。
///
/// 实测：122KB 的快照 JSON 压到 13KB 左右，这是能不能塞进网盘免费额度的关键。
enum GzipCodec {

    // MARK: - 常量

    /// gzip 魔数与压缩方法（0x08 = deflate，目前规范里唯一合法值）。
    private static let magic0: UInt8 = 0x1f
    private static let magic1: UInt8 = 0x8b
    private static let methodDeflate: UInt8 = 0x08

    /// FLG 各标志位。
    private static let flagText: UInt8 = 0x01      // FTEXT，纯提示，无附加字段
    private static let flagHeaderCRC: UInt8 = 0x02 // FHCRC，头部后跟 2 字节校验
    private static let flagExtra: UInt8 = 0x04     // FEXTRA，跟 2 字节长度 + 内容
    private static let flagName: UInt8 = 0x08      // FNAME，跟 0 结尾的文件名
    private static let flagComment: UInt8 = 0x10   // FCOMMENT，跟 0 结尾的注释
    private static let flagReserved: UInt8 = 0xE0  // 保留位，必须为 0

    /// 头(10) + 最短 deflate 数据(2) + 尾(8) = 20，比这还短的一定不是合法 gzip。
    private static let minimumFrameSize = 20

    /// 尾部长度：CRC32 + ISIZE。
    private static let trailerSize = 8

    /// 解压时允许分配的最大输出缓冲，防止损坏数据里的 ISIZE 骗我们申请一大块内存。
    /// 同步快照是百 KB 级别，1GB 的上限远远够用。
    private static let maximumOutputSize = 1 << 30

    /// 空输入对应的 raw deflate 字节：BFINAL=1 的定长哈夫曼块，内容只有一个块结束符。
    /// 单独列出来是因为 `compression_encode_buffer` 对空输入返回 0，无法和失败区分。
    private static let emptyDeflate: [UInt8] = [0x03, 0x00]

    // MARK: - 对外接口

    /// 压缩成标准 gzip 格式。失败返回 nil。
    static func compress(_ data: Data) -> Data? {
        guard let deflated = rawDeflate(data) else { return nil }

        var out = Data(capacity: deflated.count + 10 + trailerSize)
        out.append(contentsOf: [
            magic0, magic1,
            methodDeflate,
            0x00,                   // FLG：不带任何可选字段
            0x00, 0x00, 0x00, 0x00, // MTIME：填 0，保证同样输入产出同样字节
            0x00,                   // XFL
            0xff                    // OS：未知
        ])
        out.append(deflated)
        appendLittleEndian(crc32(data), to: &out)
        // ISIZE 按规范就是原始长度对 2^32 取模，超过 4GB 的输入本来就没法用这个字段表达。
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &out)
        return out
    }

    /// 解开标准 gzip 格式。头部不合法、数据损坏、CRC 或长度对不上都返回 nil。
    static func decompress(_ data: Data) -> Data? {
        guard data.count >= minimumFrameSize else { return nil }

        let bytes = [UInt8](data)
        guard bytes[0] == magic0, bytes[1] == magic1, bytes[2] == methodDeflate else { return nil }

        let flags = bytes[3]
        // 保留位非 0 说明是我们不认识的变种，宁可直接失败也不要瞎解析。
        guard flags & flagReserved == 0 else { return nil }

        // deflate 数据的右边界：尾部 8 字节之前。
        let payloadEnd = bytes.count - trailerSize
        guard let offset = skipOptionalFields(bytes, flags: flags, limit: payloadEnd) else { return nil }
        // 至少要剩下点 deflate 数据。
        guard offset < payloadEnd else { return nil }

        let expectedCRC = readLittleEndian(bytes, at: payloadEnd)
        let expectedSize = readLittleEndian(bytes, at: payloadEnd + 4)

        // 空内容单独处理：`compression_decode_buffer` 返回 0 时无法区分"解出 0 字节"和"解压失败"。
        if expectedSize == 0 {
            return expectedCRC == 0 ? Data() : nil
        }
        guard expectedSize <= UInt32(maximumOutputSize) else { return nil }

        // 缓冲区大小直接取尾部记录的原始长度，不靠"压缩比不会超过 N 倍"这种猜测——
        // 本项目实测压缩比超过 10 倍，任何固定倍数都会踩空。
        // 多要 1 字节是为了区分"正好解出 expectedSize"和"输出被缓冲区截断了"。
        let capacity = Int(expectedSize) + 1
        var out = [UInt8](repeating: 0, count: capacity)

        let written = out.withUnsafeMutableBufferPointer { dst -> Int in
            guard let dstBase = dst.baseAddress else { return 0 }
            return bytes.withUnsafeBufferPointer { src -> Int in
                guard let srcBase = src.baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, capacity,
                                                 srcBase + offset, payloadEnd - offset,
                                                 nil, COMPRESSION_ZLIB)
            }
        }

        // 解出来的长度和尾部记录对不上（截断、多余数据、损坏）一律判失败。
        guard written == Int(expectedSize) else { return nil }

        let result = Data(out[0..<written])
        guard crc32(result) == expectedCRC else { return nil }
        return result
    }

    // MARK: - 头部可选字段

    /// 跳过 FEXTRA / FNAME / FCOMMENT / FHCRC，返回 deflate 数据的起始下标。
    ///
    /// Python 的 `gzip.compress()` 默认一个可选字段都不带，但 `gzip` 命令行、
    /// 其他语言的实现常常会塞进原始文件名，所以这里要能容错。
    /// 任何一步越界都返回 nil，不做"尽量往下读"的猜测。
    private static func skipOptionalFields(_ bytes: [UInt8], flags: UInt8, limit: Int) -> Int? {
        var offset = 10
        guard offset <= limit else { return nil }

        if flags & flagExtra != 0 {
            guard offset + 2 <= limit else { return nil }
            let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLength
            guard offset <= limit else { return nil }
        }
        if flags & flagName != 0 {
            guard let next = skipZeroTerminated(bytes, from: offset, limit: limit) else { return nil }
            offset = next
        }
        if flags & flagComment != 0 {
            guard let next = skipZeroTerminated(bytes, from: offset, limit: limit) else { return nil }
            offset = next
        }
        if flags & flagHeaderCRC != 0 {
            offset += 2
            guard offset <= limit else { return nil }
        }
        return offset
    }

    /// 跳过一段以 0x00 结尾的字符串，返回结束符之后的下标；没找到结束符返回 nil。
    private static func skipZeroTerminated(_ bytes: [UInt8], from start: Int, limit: Int) -> Int? {
        var offset = start
        while offset < limit {
            if bytes[offset] == 0 { return offset + 1 }
            offset += 1
        }
        return nil
    }

    // MARK: - raw DEFLATE

    /// 用 Compression 框架做 raw deflate（不含任何容器）。
    private static func rawDeflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data(emptyDeflate) }

        // 不可压缩的内容 deflate 后会略微变大，所以起手就多留一些余量；
        // `compression_encode_buffer` 缓冲不够时返回 0，翻倍重试即可。
        var capacity = max(data.count + data.count / 8 + 64, 128)
        for _ in 0..<4 {
            var out = [UInt8](repeating: 0, count: capacity)
            let written = out.withUnsafeMutableBufferPointer { dst -> Int in
                guard let dstBase = dst.baseAddress else { return 0 }
                return data.withUnsafeBytes { src -> Int in
                    guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_encode_buffer(dstBase, capacity,
                                                     srcBase, data.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 { return Data(out[0..<written]) }
            capacity *= 2
        }
        return nil
    }

    // MARK: - CRC32

    /// CRC-32/ISO-HDLC 查表，多项式 0xEDB88320（反射形式）。首次使用时构建一次。
    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    /// 计算 gzip 尾部用的 CRC32，和 Python `zlib.crc32` 结果一致。
    static func crc32(_ data: Data) -> UInt32 {
        let table = crcTable
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - 小端读写

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    private static func readLittleEndian(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
    }
}
