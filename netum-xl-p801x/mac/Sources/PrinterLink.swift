import CoreBluetooth
import Foundation

/// A printer seen nearby that the user can choose.
struct PrinterChoice: Identifiable, Equatable {
    let id: String  // the identifier macOS gives the device
    let name: String
}

/// BLE connection to the XL-P801X with its credit-based flow control (service 0xFF00). It connects only to the
/// printer the user chose, never to another device with a similar name. The link is not paired, so not encrypted.
final class PrinterLink: NSObject, ObservableObject {
    enum Status: Equatable {
        case choose, bluetoothOff, unauthorized, searching, connecting, ready, printing
    }

    @Published private(set) var status: Status = .searching
    @Published private(set) var deviceName = ""
    @Published private(set) var progress: Double = 0
    /// The printer the user chose, remembered between launches.
    @Published private(set) var chosen: PrinterChoice?
    /// While nothing is chosen: the printers found.
    @Published private(set) var found: [PrinterChoice] = []
    var onReady: (() -> Void)?

    private static let service = CBUUID(string: "FF00")
    private static let writeChar = CBUUID(string: "FF02")
    // Never subscribe to FF01 (status): the firmware then stops returning credits.
    private static let flowChar = CBUUID(string: "FF03")
    private static let namePrefix = "XL-P801"
    private static let idKey = "printerID", nameKey = "printerName"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var credits = 0
    private var packet = 180
    private var seen: [UUID: CBPeripheral] = [:]

    private var job: PrintJob?
    private var sent = 0
    private var cancelled = false
    private var lastActivity = Date()
    private var stallTimer: Timer?
    private var completion: ((Bool) -> Void)?

    override init() {
        super.init()
        let d = UserDefaults.standard
        d.removeObject(forKey: "printerIdentifier")  // saved by older versions, which connected by themselves
        if let id = d.string(forKey: Self.idKey) {
            chosen = PrinterChoice(id: id, name: d.string(forKey: Self.nameKey) ?? "XL-P801X")
            deviceName = chosen!.name.replacingOccurrences(of: "_LE", with: "")
        }
        status = chosen == nil ? .choose : .searching
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: Choosing the printer

    /// Connects to this printer, now and on later launches.
    func choose(_ c: PrinterChoice) {
        central.stopScan()
        chosen = c
        UserDefaults.standard.set(c.id, forKey: Self.idKey)
        UserDefaults.standard.set(c.name, forKey: Self.nameKey)
        deviceName = c.name.replacingOccurrences(of: "_LE", with: "")
        found = []
        connectKnownOrScan()
    }

    /// Forgets the chosen printer and lists the printers found again. Nothing connects until one is chosen.
    func forget() {
        guard job == nil else { return }
        central.stopScan()
        if let p = peripheral {
            peripheral = nil  // so its disconnect event is ignored
            central.cancelPeripheralConnection(p)
        }
        tx = nil
        chosen = nil
        deviceName = ""
        for key in [Self.idKey, Self.nameKey] { UserDefaults.standard.removeObject(forKey: key) }
        connectKnownOrScan()
    }

    // MARK: Printing

    func send(_ job: PrintJob, completion: @escaping (Bool) -> Void) {
        guard status == .ready else { completion(false); return }
        self.job = job
        sent = 0
        cancelled = false
        progress = 0
        lastActivity = Date()
        self.completion = completion
        status = .printing
        stallTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkStall() }
        pump()
    }

    /// Stops after the current raster band (finished with blank rows) and feeds the paper.
    func cancel() {
        guard status == .printing, var j = job, !cancelled else { return }
        cancelled = true
        var cut = sent
        if let r = j.rasterRanges.first(where: { $0.contains(sent) && sent > $0.lowerBound }) {
            j.data.replaceSubrange(sent..<r.upperBound, with: Data(count: r.upperBound - sent))
            cut = r.upperBound
        }
        var data = Data(j.data.prefix(cut))
        data.append(j.data.suffix(from: j.tailStart))
        j.data = data
        job = j
    }

    private func pump() {
        guard let p = peripheral, let tx, var j = job else { return }
        while sent < j.data.count, credits > 0, p.canSendWriteWithoutResponse {
            let end = min(sent + packet, j.data.count)
            p.writeValue(j.data.subdata(in: sent..<end), for: tx, type: .withoutResponse)
            sent = end
            credits -= 1
            lastActivity = Date()
        }
        progress = j.data.isEmpty ? 1 : Double(sent) / Double(j.data.count)
        if sent >= j.data.count {
            j.data = Data()
            job = nil
            stallTimer?.invalidate()
            let ok = !cancelled
            // let the last packets leave the radio before reporting
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                if self.status == .printing { self.status = .ready }
                self.completion?(ok)
                self.completion = nil
            }
        }
    }

    /// Credits sometimes stop coming back right after connecting: nudge with one packet.
    private func checkStall() {
        guard job != nil, Date().timeIntervalSince(lastActivity) > 2 else { return }
        credits += 1
        lastActivity = Date()
        pump()
    }

    private func failJob() {
        stallTimer?.invalidate()
        job = nil
        completion?(false)
        completion = nil
    }

    // MARK: Connection

    /// With no printer chosen, it only lists what it finds and waits for the user.
    private func connectKnownOrScan() {
        guard central.state == .poweredOn else { return }
        guard let c = chosen, let id = UUID(uuidString: c.id) else {
            status = .choose
            seen = [:]
            found = []
            central.scanForPeripherals(withServices: nil, options: nil)
            return
        }
        status = .searching
        if let p = seen[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)  // pending until the printer is switched on
        }
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    private func connect(_ p: CBPeripheral) {
        if peripheral !== p, let old = peripheral { central.cancelPeripheralConnection(old) }
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    func reconnect() {
        if let p = peripheral {
            peripheral = nil
            central.cancelPeripheralConnection(p)
        }
        tx = nil
        connectKnownOrScan()
    }
}

extension PrinterLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: connectKnownOrScan()
        case .unauthorized: status = .unauthorized
        default:
            status = .bluetoothOff
            tx = nil
            failJob()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? ""
        guard name.hasPrefix(Self.namePrefix) else { return }
        if let c = chosen {
            // Only the printer the user chose, never another device with a similar name.
            guard c.id == p.identifier.uuidString else { return }
            central.stopScan()
            status = .connecting
            connect(p)
        } else if status == .choose {
            seen[p.identifier] = p
            guard !found.contains(where: { $0.id == p.identifier.uuidString }) else { return }
            found.append(PrinterChoice(id: p.identifier.uuidString, name: name))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral else { central.cancelPeripheralConnection(p); return }
        central.stopScan()
        status = .connecting
        if deviceName.isEmpty { deviceName = (p.name ?? "XL-P801X").replacingOccurrences(of: "_LE", with: "") }
        p.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.connectKnownOrScan() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }  // a printer left behind by "Change printer"
        tx = nil
        failJob()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.connectKnownOrScan() }
    }
}

extension PrinterLink: CBPeripheralDelegate {
    // A printer given up by Change printer may still answer: only the current one counts.
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral, let s = p.services?.first(where: { $0.uuid == Self.service }) else { return }
        p.discoverCharacteristics([Self.writeChar, Self.flowChar], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard p === peripheral else { return }
        for c in s.characteristics ?? [] {
            if c.uuid == Self.writeChar { tx = c }
            if c.uuid == Self.flowChar { p.setNotifyValue(true, for: c) }
        }
        packet = min(180, p.maximumWriteValueLength(for: .withoutResponse))
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, c.uuid == Self.flowChar, c.isNotifying, tx != nil else { return }
        credits = 0
        // the initial credit grant arrives right after subscribing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.tx != nil else { return }
            self.status = .ready
            self.onReady?()
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, c.uuid == Self.flowChar, let v = c.value, v.count >= 2 else { return }
        let b = [UInt8](v)
        if b[0] == 0x01 {
            credits += Int(b[1])
            if job != nil { lastActivity = Date(); pump() }
        } else if b[0] == 0x02, b.count >= 3 {
            packet = min(packet, Int(b[1]) | Int(b[2]) << 8)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        pump()
    }
}
