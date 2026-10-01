import Foundation
import Testing

@testable import CC2Kit

struct RegistrationTests {
    @Test(arguments: [
        ("register_ok", RegistrationOutcome.registered),
        ("register_already", .registered),
        ("register_too_many", .tooManyClients),
    ])
    func parsesRecordedResponses(fixture: String, expected: RegistrationOutcome) throws {
        let data = try Data(contentsOf: fixtureURL(fixture, "json"))
        #expect(CC2Protocol.parseRegisterResponse(data) == expected)
    }

    @Test func unknownErrorIsFailed() {
        let raw = #"{"client_id":"x","error":"weird"}"#
        #expect(CC2Protocol.parseRegisterResponse(Data(raw.utf8)) == .failed(raw: raw))
    }

    @Test func topics() {
        let topics = CC2Protocol.Topics(serial: "SN", clientId: "C")
        #expect(topics.status == "elegoo/SN/api_status")
        #expect(topics.register == "elegoo/SN/api_register")
        #expect(topics.registerResponse == "elegoo/SN/C/register_response")
        #expect(topics.request == "elegoo/SN/C/api_request")
        #expect(topics.response == "elegoo/SN/C/api_response")
    }

    @Test func registerPayloadCarriesBothIds() throws {
        let json = try #require(
            try JSONSerialization.jsonObject(with: CC2Protocol.registerPayload(clientId: "cc2mon1"))
                as? [String: String])
        #expect(json == ["request_id": "cc2mon1", "client_id": "cc2mon1"])
    }

    @Test func newClientIdFormat() {
        let id = CC2Protocol.newClientId()
        #expect(id.hasPrefix("cc2mon"))
        #expect(id.count == 14)
        #expect(id.dropFirst(6).allSatisfy { $0.isHexDigit })
    }

    @Test func pongIsRecognised() throws {
        let pong = try Data(contentsOf: fixtureURL("pong", "json"))
        #expect(CC2Protocol.isPong(pong))
        #expect(!CC2Protocol.isPong(Data(#"{"id":1,"method":1002,"result":{}}"#.utf8)))
    }

    @Test func snapshotResponseIsRecognised() throws {
        let data = try Data(contentsOf: fixtureURL("get_basic_info_response", "json"))
        #expect(CC2Protocol.decodeSnapshot(data) != nil)
        let pong = try Data(contentsOf: fixtureURL("pong", "json"))
        #expect(CC2Protocol.decodeSnapshot(pong) == nil)
    }
}

struct ResyncTests {
    @Test(arguments: [
        (RegistrationMode.stay, StatusChannelState.online, ResyncAction.requestSnapshot),
        (.brief, .online, .registerBriefly),
        (.never, .limited, .resetPrintFields),
        (.stay, .limited, .resetPrintFields),
        (.stay, .registrationFailed, .resetPrintFields),
    ])
    func resync(mode: RegistrationMode, channel: StatusChannelState, expected: ResyncAction) {
        #expect(resyncAction(mode: mode, channel: channel) == expected)
    }

    @Test func defaultModeIsStay() {
        #expect(RegistrationMode.default == .stay)
    }
}
