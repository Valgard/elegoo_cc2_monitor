import Testing

@testable import CC2Kit

private func status(_ configure: (inout PrinterStatus) -> Void) -> PrinterStatus {
    var s = PrinterStatus()
    configure(&s)
    return s
}

struct StatusFormatterTests {
    @Test func layerWithAndWithoutTotal() {
        #expect(
            StatusFormatter.layer(
                status {
                    $0.currentLayer = 68
                    $0.totalLayers = 120
                }) == "68 / 120")
        #expect(StatusFormatter.layer(status { $0.currentLayer = 68 }) == "68")
        #expect(StatusFormatter.layer(PrinterStatus()) == "–")
    }

    @Test(arguments: [(2385, "0:39"), (3600, "1:00"), (0, "0:00")])
    func remainingAsHoursMinutes(seconds: Int, expected: String) {
        #expect(StatusFormatter.remaining(status { $0.remainingSeconds = seconds }) == expected)
    }

    @Test func negativeRemainingShowsDash() {
        #expect(StatusFormatter.remaining(status { $0.remainingSeconds = -1 }) == "–")
        #expect(StatusFormatter.remaining(PrinterStatus()) == "–")
    }

    @Test func stateLabels() {
        #expect(StatusFormatter.state(status { $0.machineState = 2 }) == "Druckt")
        #expect(StatusFormatter.state(status { $0.machineState = 1 }) == "Bereit")
        #expect(StatusFormatter.state(status { $0.machineState = 17 }) == "Fremdkörper erkannt")
        #expect(StatusFormatter.state(status { $0.machineState = 99 }) == "Status 99")
        #expect(StatusFormatter.state(PrinterStatus()) == "–")
    }

    @Test func temperatureRounds() {
        #expect(StatusFormatter.temperature(224.6) == "225 °C")
        #expect(StatusFormatter.temperature(nil) == "–")
    }

    @Test func progressPercent() {
        #expect(StatusFormatter.progress(status { $0.progress = 23 }) == "23 %")
        #expect(StatusFormatter.progress(PrinterStatus()) == "–")
    }

    @Test func fileName() {
        #expect(StatusFormatter.fileName(status { $0.fileName = "helm.gcode" }) == "helm.gcode")
        #expect(StatusFormatter.fileName(PrinterStatus()) == "–")
    }
}
