import Foundation

public enum DaikinClientError: Error, LocalizedError, Equatable, Sendable {
    case invalidKey
    case invalidState
    case unsupportedCommand

    public var errorDescription: String? {
        switch self {
        case .invalidKey: "Enter the Daikin integration key from the Daikin Smart AC app."
        case .invalidState: "The Daikin device returned an unreadable state."
        case .unsupportedCommand: "This Daikin function is not supported by the documented local protocol."
        }
    }
}

/// Provider for Daikin units on the same local network as this Mac.
public struct DaikinClient: ACProvider {
    public static let localCapabilities = ACCapabilities(
        modes: [ACMode.auto, ACMode.dry, ACMode.cool, ACMode.heat, ACMode.fan],
        fanSpeeds: ["LOW", "MID_LOW", "MID", "MID_HIGH", "HIGH", "AUTO", "SILENT"],
        minTemperature: 18, maxTemperature: 30, temperatureStep: 1,
        supportsEco: true, supportsSwing: true, supportsSleep: false
    )

    private let key: Data
    private let transport: DaikinLocalTransport

    public init(address: String, key: String, transport: DaikinLocalTransport? = nil) throws {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyData = Data(normalized.utf8)
        guard [16, 24, 32].contains(keyData.count) else { throw DaikinClientError.invalidKey }
        self.key = keyData
        self.transport = transport ?? DaikinLocalTransport(address: address)
    }

    public func devices() async throws -> [ACDevice] {
        [ACDevice(id: "daikin-local", provider: .daikin, displayName: "Daikin air conditioner")]
    }

    public func capabilities(deviceID: String) async throws -> ACCapabilities {
        try validate(deviceID)
        return Self.localCapabilities
    }

    public func status(deviceID: String) async throws -> ACStatus {
        try validate(deviceID)
        let response = try await transport.request(method: "GET", path: "/acstatus")
        let frame = try decodeBase64Body(response)
        let plaintext = try DaikinCrypto.decode(frame, key: key, route: .acstatus)
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: plaintext), let port = json["port1"] else {
            throw DaikinClientError.invalidState
        }
        let modeCode = Int(port["mode"]?.double ?? -1)
        let fanCode = Int(port["fan"]?.double ?? -1)
        return ACStatus(
            isOn: port["power"]?.double == 1,
            mode: Self.modeName(modeCode),
            currentTemperature: port["sensors"]?["room_temp"]?.double,
            targetTemperature: port["temperature"]?.double,
            fanSpeed: Self.fanName(fanCode),
            swing: port["v_swing"]?.double.map { $0 == 1 },
            eco: port["econo"]?.double.map { $0 == 1 },
            sleepMinutesLeft: nil
        )
    }

    public func send(_ command: ACCommand, deviceID: String) async throws {
        try validate(deviceID)
        var fields: [String: JSONValue] = [:]
        switch command {
        case .power(let on): fields["power"] = .number(on ? 1 : 0)
        case .mode(let mode): fields["mode"] = .number(try Self.modeCode(mode))
        case .targetTemperature(let temperature): fields["temperature"] = .number(temperature)
        case .fanSpeed(let fan): fields["fan"] = .number(try Self.fanCode(fan))
        case .swing(let on): fields["v_swing"] = .number(on ? 1 : 0)
        case .eco(let on): fields["econo"] = .number(on ? 1 : 0)
        case .sleep: throw DaikinClientError.unsupportedCommand
        }
        let payload = try JSONEncoder().encode(JSONValue.object(["port1": .object(fields)]))
        let encrypted = try DaikinCrypto.encode(payload, key: key)
        let body = Data(encrypted.base64EncodedString().utf8)
        let response = try await transport.request(method: "POST", path: "/acstatus", body: body)
        let responseFrame = try decodeBase64Body(response)
        _ = try DaikinCrypto.decode(responseFrame, key: key, route: .acstatus)
    }

    private func validate(_ deviceID: String) throws {
        guard deviceID == "daikin-local" else { throw DaikinClientError.invalidState }
    }

    private func decodeBase64Body(_ body: Data) throws -> Data {
        let encoded = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let frame = Data(base64Encoded: encoded) else { throw DaikinClientError.invalidState }
        return frame
    }

    private static func modeName(_ code: Int) -> String {
        switch code {
        case 0: ACMode.auto
        case 2: ACMode.dry
        case 3: ACMode.cool
        case 4: ACMode.heat
        case 6: ACMode.fan
        default: "DAIKIN_MODE_\(code)"
        }
    }

    private static func modeCode(_ mode: String) throws -> Int {
        switch mode {
        case ACMode.auto: 0
        case ACMode.dry: 2
        case ACMode.cool: 3
        case ACMode.heat: 4
        case ACMode.fan: 6
        default: try rawCode(mode, prefix: "DAIKIN_MODE_")
        }
    }

    private static func fanName(_ code: Int) -> String {
        switch code {
        case 3: "LOW"
        case 4: "MID_LOW"
        case 5: "MID"
        case 6: "MID_HIGH"
        case 7: "HIGH"
        case 17: "AUTO"
        case 18: "SILENT"
        default: "DAIKIN_FAN_\(code)"
        }
    }

    private static func fanCode(_ fan: String) throws -> Int {
        switch fan {
        case "LOW": 3
        case "MID_LOW": 4
        case "MID": 5
        case "MID_HIGH": 6
        case "HIGH": 7
        case "AUTO": 17
        case "SILENT": 18
        default: try rawCode(fan, prefix: "DAIKIN_FAN_")
        }
    }

    private static func rawCode(_ value: String, prefix: String) throws -> Int {
        guard value.hasPrefix(prefix), let code = Int(value.dropFirst(prefix.count)) else {
            throw DaikinClientError.unsupportedCommand
        }
        return code
    }
}
