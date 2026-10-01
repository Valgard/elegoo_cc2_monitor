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

/// Answer to `api_register`.
public enum RegistrationOutcome: Equatable, Sendable {
    /// `"ok"` or `"already registered"` (a registration survives a dropped connection).
    case registered
    /// `"too many clients"`: the printer's client slots (about 10) are full.
    case tooManyClients
    /// Anything else, kept raw for the log.
    case failed(raw: String)
}

extension CC2Protocol {
    public struct Topics: Sendable {
        public let status: String
        public let register: String
        public let registerResponse: String
        public let request: String
        public let response: String

        public init(serial: String, clientId: String) {
            status = "elegoo/\(serial)/api_status"
            register = "elegoo/\(serial)/api_register"
            registerResponse = "elegoo/\(serial)/\(clientId)/register_response"
            request = "elegoo/\(serial)/\(clientId)/api_request"
            response = "elegoo/\(serial)/\(clientId)/api_response"
        }
    }

    public static let getBasicInfo = 1002
    public static let messageAutoReport = 6000

    /// `cc2mon` + 8 hex digits — accepted by the printer and recognisable among its clients.
    public static func newClientId() -> String {
        "cc2mon" + String(format: "%08x", UInt32.random(in: .min ... .max))
    }

    /// The printer only answers when both ids are present (and the message is sent with QoS 1).
    public static func registerPayload(clientId: String) -> Data {
        Data(#"{"request_id":"\#(clientId)","client_id":"\#(clientId)"}"#.utf8)
    }

    public static func snapshotRequest(id: Int) -> Data {
        Data(#"{"id":\#(id),"method":\#(getBasicInfo),"params":{}}"#.utf8)
    }

    public static let ping = Data(#"{"type":"PING"}"#.utf8)

    public static func parseRegisterResponse(_ data: Data) -> RegistrationOutcome {
        struct Response: Decodable { let error: String }
        switch (try? JSONDecoder().decode(Response.self, from: data))?.error {
        case "ok", "already registered": return .registered
        case "too many clients": return .tooManyClients
        default: return .failed(raw: String(decoding: data, as: UTF8.self))
        }
    }

    public static func isPong(_ data: Data) -> Bool {
        struct Message: Decodable { let type: String? }
        return (try? JSONDecoder().decode(Message.self, from: data))?.type == "PONG"
    }
}
