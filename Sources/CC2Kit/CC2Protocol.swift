import Foundation

/// The sections of an `api_status` report or a `GetBasicInfo` result that the app uses.
/// Every field is optional: a delta only carries what changed.
public struct StatusDelta: Decodable, Equatable, Sendable {
    public struct Temperature: Decodable, Equatable, Sendable {
        public var temperature: Double?
    }

    public struct PrintSection: Decodable, Equatable, Sendable {
        public var currentLayer: Int?
        public var totalLayers: Int?
        public var remainingTimeSec: Int?
        public var filename: String?

        enum CodingKeys: String, CodingKey {
            case currentLayer = "current_layer"
            case totalLayers = "total_layer"
            case remainingTimeSec = "remaining_time_sec"
            case filename
        }
    }

    public struct MachineSection: Decodable, Equatable, Sendable {
        public var status: Int?
        public var progress: Int?
    }

    public var extruder: Temperature?
    public var heaterBed: Temperature?
    public var printStatus: PrintSection?
    public var machineStatus: MachineSection?

    enum CodingKeys: String, CodingKey {
        case extruder
        case heaterBed = "heater_bed"
        case printStatus = "print_status"
        case machineStatus = "machine_status"
    }
}

/// One message on `elegoo/<sn>/api_status`.
public struct AutoReport: Decodable, Sendable {
    public let id: Int
    public let method: Int
    /// `nil` when the result does not have the expected shape (e.g. other report types);
    /// the id still counts for gap detection.
    public let result: StatusDelta?

    enum CodingKeys: String, CodingKey {
        case id, method, result
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        method = try container.decode(Int.self, forKey: .method)
        result = try? container.decodeIfPresent(StatusDelta.self, forKey: .result)
    }
}

public enum CC2Protocol {
    public static func decodeAutoReport(_ data: Data) -> AutoReport? {
        try? JSONDecoder().decode(AutoReport.self, from: data)
    }

    /// Decodes the `result` of a `GetBasicInfo` response.
    public static func decodeSnapshot(_ data: Data) -> StatusDelta? {
        struct Response: Decodable { let result: StatusDelta }
        return try? JSONDecoder().decode(Response.self, from: data).result
    }
}
