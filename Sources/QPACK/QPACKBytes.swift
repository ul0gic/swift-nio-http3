import HTTPTypes

@_spi(PackageInternal)
public struct QPACKBytes: Sendable, Hashable, ExpressibleByStringLiteral {
    let bytes: [UInt8]

    public init(_ bytes: some Collection<UInt8>) {
        self.bytes = Array(bytes)
    }

    public init(utf8 string: String) {
        self.bytes = Array(string.utf8)
    }

    public init(stringLiteral value: String) {
        self.init(utf8: value)
    }

    public var count: Int { self.bytes.count }

    public func withUnsafeBytes<Result>(_ body: (UnsafeBufferPointer<UInt8>) -> Result) -> Result {
        self.bytes.withUnsafeBufferPointer(body)
    }

    @available(anyAppleOS 27, *)
    func withBytes<Result>(_ body: (Span<UInt8>) -> Result) -> Result {
        self.bytes.withUnsafeBufferPointer { body($0.span) }
    }

    init(field: HTTPField) {
        self = field.withUnsafeBytesOfValue { Self($0) }
    }
}
