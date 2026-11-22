import CoreBluetooth
import Foundation

enum PrintResult {
    case printed(confirmed: Bool)
    case stopped
    case failed(String)
}

/// How the app reaches the printer.
enum LinkKind: String {
    /// The Classic Bluetooth serial port, once paired in System Settings: authenticated and encrypted.
    case serial
    /// Bluetooth LE: no pairing, so neither authenticated nor encrypted (notes, 43).
    case ble

    var label: String {
        switch self {
        case .serial: "Paired link (encrypted)"
        case .ble: "Bluetooth LE (not encrypted)"
        }
    }
}

/// A printer the user can choose: a paired serial port, or a Bluetooth LE device seen nearby.
struct PrinterChoice: Identifiable, Equatable {
    let kind: LinkKind
    let id: String  // serial: the printer's Bluetooth address; Bluetooth LE: the identifier macOS gives the device
    let name: String
    var shortName: String { name.replacingOccurrences(of: "_BLE", with: "") }
}

/// Connection to the S1, over its paired serial port or over BLE (service 0xFF00: replies on FF01, data on FF02,
/// credits on FF03). It connects only to the printer the user chose, never to another device with a similar name.
/// It talks only to the printer, and sends only printing commands and one read-only battery query.
final class PrinterLink: NSObject, ObservableObject {
    enum Status: Equatable {
        case choose, bluetoothOff, unauthorized, offline, searching, connecting, noAnswer, ready, printing, stopping
    }

    @Published private(set) var status: Status = .searching
    @Published private(set) var deviceName = ""
    @Published private(set) var battery: Int?
    @Published private(set) var progress: Double = 0
    @Published private(set) var secondsLeft: Int?
    /// The printer the user chose, remembered between launches.
    @Published private(set) var chosen: PrinterChoice?
    /// While nothing is chosen: the printers found, paired serial ports first.
    @Published private(set) var found: [PrinterChoice] = []
    /// The paired S1 printers that macOS lists now, by Bluetooth address.
    @Published private(set) var serialPorts: [String] = []
    var onReady: (() -> Void)?
    var link: LinkKind? { chosen?.kind }
    /// Over the paired link Stop finishes the current page first (see `stop`).
    var stoppingText: String { port != nil ? "Finishing this page…" : "Stopping…" }

    private static let service = CBUUID(string: "FF00")
    private static let replyChar = CBUUID(string: "FF01")
    private static let writeChar = CBUUID(string: "FF02")
    private static let flowChar = CBUUID(string: "FF03")
    private static let prefixes = ["PPS1", "S1_"]
    private static let kindKey = "printerLink", idKey = "printerID", nameKey = "printerName"
    private static let creditTimeout: TimeInterval = 15
    private static let okTimeout: TimeInterval = 20
    private static let answerTimeout: TimeInterval = 5
    // Serial link. No OK came over it in the one test so far (notes, 43), so a job ends after the last write,
    // the last packet leaving, and this short wait.
    private static let serialChunk = 512
    private static let serialOKWait: TimeInterval = 3
    private static let drainLimit: TimeInterval = 30

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var credits = 0
    private var packet = 200
    private var wantsConnection = true
    private var askingBattery = false
    private var seen: [UUID: CBPeripheral] = [:]
    private var bleFound: [PrinterChoice] = []

    private var port: SerialPort?
    private var rx: [UInt8] = []
    private var inFlight = 0
    private var jobToken = 0
    private var answerToken = 0
    private var retryTimer: Timer?
    private var listTimer: Timer?

    private var sender: JobSender?
    private var waiting = false
    private var completion: ((PrintResult) -> Void)?
    private var started = Date()
    private var lastProgress = Date()
    private var rasterEnd: Date?
    private var lastOK: Date?
    private var okDeadline: Date?
    private var watchdog: Timer?

    override init() {
        super.init()
        chosen = Self.loadChoice()
        deviceName = chosen?.shortName ?? ""
        status = chosen == nil ? .choose : .searching
        central = CBCentralManager(delegate: self, queue: nil)
        refreshPorts()
        // Paired ports come and go as the printer is paired, removed, or switched on and off.
        listTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPorts() }
        if chosen?.kind == .serial { openSerial() }
    }

    // MARK: Choosing the printer

    /// Connects to this printer, now and on later launches.
    func choose(_ c: PrinterChoice) {
        closeLinks()
        chosen = c
        Self.save(c)
        deviceName = c.shortName
        found = []
        bleFound = []
        wantsConnection = true
        status = .searching
        start()
    }

    /// Forgets the chosen printer and lists the printers found again. Nothing connects until one is chosen.
    func forget() {
        guard sender == nil else { return }
        closeLinks()
        chosen = nil
        Self.save(nil)
        deviceName = ""
        wantsConnection = true
        start()
    }

    private func start() {
        guard wantsConnection else { return }
        switch chosen?.kind {
        case .serial?:
            openSerial()
        case .ble?:
            connectKnownOrScan()
        case nil:
            seen = [:]
            bleFound = []
            switch central.state {
            case .unauthorized:
                status = .unauthorized
            case .poweredOff, .unsupported:
                status = .bluetoothOff
            default:
                // Lists what it finds and waits for the user: nothing is connected from this list by itself.
                status = .choose
                updateFound()
                if central.state == .poweredOn { central.scanForPeripherals(withServices: nil, options: nil) }
            }
        }
    }

    private func refreshPorts() {
        let ports = SerialPort.candidates()
        if ports != serialPorts { serialPorts = ports }
        if status == .choose { updateFound() }
    }

    private func updateFound() {
        let all = serialPorts.map { PrinterChoice(kind: .serial, id: $0, name: SerialPort.displayName($0)) } + bleFound
        if all != found { found = all }
    }

    private func closeLinks() {
        retryTimer?.invalidate()
        retryTimer = nil
        central.stopScan()
        if let p = peripheral {
            peripheral = nil  // so its disconnect event is ignored
            central.cancelPeripheralConnection(p)
        }
        tx = nil
        credits = 0
        closeSerial()
        battery = nil
    }

    private static func loadChoice() -> PrinterChoice? {
        let d = UserDefaults.standard
        d.removeObject(forKey: "printerIdentifier")  // saved by older versions, which connected by themselves
        guard let kind = d.string(forKey: kindKey).flatMap(LinkKind.init(rawValue:)), let id = d.string(forKey: idKey) else { return nil }
        if kind == .serial && !SerialPort.isCandidate(id) { return nil }  // only an S1's paired port is ever opened
        return PrinterChoice(kind: kind, id: id, name: d.string(forKey: nameKey) ?? "S1")
    }

    private static func save(_ c: PrinterChoice?) {
        let d = UserDefaults.standard
        if let c {
            d.set(c.kind.rawValue, forKey: kindKey)
            d.set(c.id, forKey: idKey)
            d.set(c.name, forKey: nameKey)
        } else {
            for key in [kindKey, idKey, nameKey] { d.removeObject(forKey: key) }
        }
    }

    // MARK: Printing

    func send(_ job: PrintJob, completion: @escaping (PrintResult) -> Void) {
        guard status == .ready else { completion(.failed("The printer is not connected.")); return }
        sender = JobSender(job)
        waiting = false
        rasterEnd = nil
        lastOK = nil
        okDeadline = nil
        progress = 0
        secondsLeft = nil
        jobToken += 1
        inFlight = 0
        started = Date()
        lastProgress = started
        self.completion = completion
        status = .printing
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkStall() }
        pump()
    }

    /// Over BLE, ends sending at once, on a whole row. The printer drops the unfinished raster after a pause,
    /// so no disconnect and no blank rows are needed. Over the paired serial link, ends after the current page.
    func stop() {
        guard status == .printing, let s = sender, !s.isDone else { return }
        status = .stopping
        sender?.stop(finishPage: port != nil)
        pump()
    }

    private func pump() {
        if let port { pumpSerial(port) } else { pumpBLE() }
    }

    private func pumpBLE() {
        guard let p = peripheral, let tx, sender != nil, !waiting else { return }
        // One credit allows one packet. No credit is ever invented: a printer that stops granting them gets no more data.
        while credits > 0, p.canSendWriteWithoutResponse, let chunk = sender?.next(packet: packet) {
            credits -= 1
            p.writeValue(chunk, for: tx, type: .withoutResponse)
            if sender?.lastChunkWasRaster == true { rasterEnd = Date() }
            lastProgress = Date()
        }
        updateProgress()
        guard let s = sender else { return }
        if s.mustWait {
            waiting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Head.stopWait) { [weak self] in
                guard let self, self.sender != nil else { return }
                self.waiting = false
                self.sender?.resumeAfterWait()
                self.pump()
            }
        } else if s.isDone {
            if s.stopped {
                finish(.stopped)
            } else if okArrived {
                finish(.printed(confirmed: true))
            } else if okDeadline == nil {
                // The printer answers OK shortly after a raster ends. Closing the link earlier could cut the print.
                okDeadline = Date().addingTimeInterval(Self.okTimeout)
            }
        }
    }

    /// At most two chunks wait in the port's queue, so a stop takes effect soon.
    private func pumpSerial(_ port: SerialPort) {
        guard sender != nil, !waiting else { return }
        let token = jobToken
        while inFlight < 2, let chunk = sender?.next(packet: Self.serialChunk) {
            inFlight += 1
            if sender?.lastChunkWasRaster == true { rasterEnd = Date() }
            port.send(chunk) { [weak self] error in self?.serialWritten(error, token: token) }
        }
        updateProgress()
        // Over this link a stop never leaves a raster open (it finishes the page), so there is no wait in the middle.
        guard inFlight == 0, let s = sender, s.isDone else { return }
        waiting = true
        // A write ends when macOS has the bytes, not when the printer has them: wait for the port's queue to empty,
        // also after a stop, so that Disconnect right after it does not cut the page.
        port.waitUntilSent(limit: Self.drainLimit) { [weak self] drained in
            guard let self, let s = self.sender, self.jobToken == token else { return }
            if !drained { self.finish(.failed("The printer stopped accepting data. Check the paper and the lid.")) }
            else if s.stopped { self.finish(.stopped) }
            else if self.okArrived { self.finish(.printed(confirmed: true)) }
            else { self.okDeadline = Date().addingTimeInterval(Self.serialOKWait) }
        }
    }

    private func serialWritten(_ error: String?, token: Int) {
        guard token == jobToken, sender != nil else { return }
        inFlight -= 1
        if let error { finish(.failed(error)); return }
        lastProgress = Date()
        pump()
    }

    private func updateProgress() {
        guard let s = sender else { return }
        progress = s.total == 0 ? 1 : Double(s.sent) / Double(s.total)
        let elapsed = Date().timeIntervalSince(started)
        if s.sent > 0, elapsed > 0 { secondsLeft = Int((Double(s.total - s.sent) / (Double(s.sent) / elapsed)).rounded(.up)) }
    }

    private var okArrived: Bool {
        guard let end = rasterEnd else { return true }
        return lastOK.map { $0 >= end } ?? false
    }

    private func checkStall() {
        if let deadline = okDeadline {
            if okArrived { finish(.printed(confirmed: true)) }
            else if Date() > deadline { finish(.printed(confirmed: false)) }
        } else if port == nil, sender != nil, !waiting, credits <= 0, Date().timeIntervalSince(lastProgress) > Self.creditTimeout {
            finish(.failed("The printer stopped accepting data. Check the paper and the lid."))
        }
    }

    private func finish(_ result: PrintResult) {
        if case .failed = result { port?.cancelWrites(); port?.discardOutput() }
        watchdog?.invalidate()
        watchdog = nil
        okDeadline = nil
        sender = nil
        waiting = false
        inFlight = 0
        secondsLeft = nil
        if status == .printing || status == .stopping { status = .ready }
        let done = completion
        completion = nil
        done?(result)
    }

    // MARK: Connection

    func connectAgain() {
        wantsConnection = true
        start()
    }

    /// Frees the printer for another app or browser: it accepts one connection at a time.
    func disconnect() {
        wantsConnection = false
        retryTimer?.invalidate()
        retryTimer = nil
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        if port != nil {
            closeSerial()
            battery = nil
            if sender != nil { finish(.failed("Disconnected.")) }
        }
        if status != .bluetoothOff && status != .unauthorized { status = .offline }
    }

    // MARK: Serial link

    private func openSerial() {
        guard wantsConnection, let c = chosen, c.kind == .serial, port == nil else { return }
        retryTimer?.invalidate()
        retryTimer = nil
        guard SerialPort.candidates().contains(c.id) else {
            // Not paired with this Mac (any more), or macOS does not list the printer yet.
            status = .searching
            retrySerial()
            return
        }
        if status != .noAnswer { status = .connecting }
        let p = SerialPort(address: c.id) { [weak self] source, event in self?.serialEvent(event, from: source) }
        port = p
        p.open { [weak self] error in
            guard let self else { p.close(); return }
            guard self.port === p else { p.close(); return }
            if error != nil {
                self.port = nil
                self.status = self.central.state == .poweredOff ? .bluetoothOff : .searching
                self.retrySerial()
                return
            }
            // Read-only. The answer is also the sign that what answered is the printer.
            self.rx = []
            self.askingBattery = true
            self.answerToken += 1
            let token = self.answerToken
            p.send(Data([0x10, 0xFF, 0x50, 0xF1])) { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.answerTimeout) { [weak self] in
                guard let self, self.port === p, self.answerToken == token, self.askingBattery else { return }
                self.closeSerial()
                self.status = .noAnswer
                self.retrySerial()
            }
        }
    }

    private func retrySerial() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.openSerial() }
    }

    private func closeSerial() {
        port?.close()
        port = nil
        askingBattery = false
        rx = []
    }

    private func serialEvent(_ event: SerialPort.Event, from source: SerialPort) {
        guard source === port else { return }
        switch event {
        case .bytes(let bytes):
            serialBytes(bytes)
        case .closed(let reason):
            closeSerial()
            battery = nil
            if sender != nil { finish(.failed(reason)) }
            guard wantsConnection else { status = .offline; return }
            status = .searching
            retrySerial()
        }
    }

    /// Replies arrive as a stream here, not as separate messages: the battery level is `00 nn`, a finished job `OK`.
    private func serialBytes(_ bytes: [UInt8]) {
        rx = Array((rx + bytes).suffix(16))
        if askingBattery, let i = rx.indices.dropLast().first(where: { rx[$0] == 0 && rx[$0 + 1] <= 100 }) {
            askingBattery = false
            battery = Int(rx[i + 1])
            rx.removeSubrange(...(i + 1))
            if status == .connecting || status == .noAnswer {
                status = .ready
                onReady?()
            }
        }
        while let i = rx.indices.dropLast().first(where: { rx[$0] == 0x4F && rx[$0 + 1] == 0x4B }) {
            rx.removeSubrange(...(i + 1))
            lastOK = Date()
            if okDeadline != nil, okArrived { finish(.printed(confirmed: true)) }
        }
    }

    // MARK: Bluetooth LE link

    private func connectKnownOrScan() {
        guard central.state == .poweredOn, wantsConnection, let c = chosen, c.kind == .ble, let id = UUID(uuidString: c.id) else { return }
        if status != .noAnswer { status = .searching }
        if let p = seen[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)  // stays pending until the printer is switched on
        }
        central.scanForPeripherals(withServices: nil, options: nil)  // it advertises no service UUID
    }

    private func connect(_ p: CBPeripheral) {
        if let old = peripheral, old !== p { central.cancelPeripheralConnection(old) }
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    private func linkLost(_ message: String) {
        tx = nil
        credits = 0
        battery = nil
        if sender != nil { finish(.failed(message)) }
    }

    private func becomeReady(_ p: CBPeripheral) {
        guard let tx, status != .ready else { return }
        status = .ready
        // Read-only and optional: printing works whether or not this gets an answer.
        credits -= 1
        askingBattery = true
        p.writeValue(Data([0x10, 0xFF, 0x50, 0xF1]), for: tx, type: .withoutResponse)
        onReady?()
    }
}

extension PrinterLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // The serial link has its own errors; this only reports Bluetooth for the LE link and for the list.
        guard chosen?.kind != .serial else { return }
        switch central.state {
        case .poweredOn:
            if wantsConnection { start() } else { status = .offline }
        case .unauthorized:
            status = .unauthorized
            linkLost("Bluetooth is not allowed.")
        default:
            status = .bluetoothOff
            linkLost("Bluetooth went off.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? ""
        guard Self.prefixes.contains(where: name.hasPrefix) else { return }
        if let c = chosen {
            // Only the printer the user chose, never another device with a similar name.
            guard c.kind == .ble, c.id == p.identifier.uuidString else { return }
            central.stopScan()
            connect(p)
        } else if status == .choose {
            seen[p.identifier] = p
            guard !bleFound.contains(where: { $0.id == p.identifier.uuidString }) else { return }
            bleFound.append(PrinterChoice(kind: .ble, id: p.identifier.uuidString, name: name))
            updateFound()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral else { central.cancelPeripheralConnection(p); return }
        central.stopScan()
        if status != .noAnswer { status = .connecting }
        p.discoverServices([Self.service])
        // Credits arrive right after subscribing. None came in the one case seen, with the USB cable plugged in.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.answerTimeout) { [weak self] in
            guard let self, self.peripheral === p, self.credits <= 0, self.wantsConnection,
                  self.status == .connecting || self.status == .noAnswer else { return }
            self.status = .noAnswer
            central.cancelPeripheralConnection(p)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.connectKnownOrScan() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }  // a printer left behind by "Change printer"
        linkLost("The printer disconnected.")
        guard wantsConnection else { status = .offline; return }
        if status != .noAnswer { status = .searching }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.connectKnownOrScan() }
    }
}

extension PrinterLink: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral, let s = p.services?.first(where: { $0.uuid == Self.service }) else { return }
        p.discoverCharacteristics([Self.replyChar, Self.writeChar, Self.flowChar], for: s)
    }

    // A printer given up by Change printer may still answer: only the current one counts.
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard p === peripheral else { return }
        credits = 0
        for c in s.characteristics ?? [] {
            if c.uuid == Self.writeChar { tx = c }
            if c.uuid == Self.replyChar || c.uuid == Self.flowChar { p.setNotifyValue(true, for: c) }
        }
        packet = min(200, p.maximumWriteValueLength(for: .withoutResponse))
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, let v = c.value else { return }
        let b = [UInt8](v)
        if c.uuid == Self.flowChar {
            if b.count >= 2, b[0] == 0x01 {
                credits += Int(b[1])
                if status == .connecting || status == .noAnswer { becomeReady(p) } else { pump() }
            } else if b.count >= 3, b[0] == 0x02 {
                packet = min(packet, Int(b[1]) | Int(b[2]) << 8)
            }
        } else if c.uuid == Self.replyChar {
            if b == [0x4F, 0x4B] {
                lastOK = Date()
                if okDeadline != nil, okArrived { finish(.printed(confirmed: true)) }
            } else if askingBattery, b.count == 2, b[0] == 0, b[1] <= 100 {
                askingBattery = false
                battery = Int(b[1])
            }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        pump()
    }
}
