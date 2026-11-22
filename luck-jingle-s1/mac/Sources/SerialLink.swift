import Foundation
import IOBluetooth

/// The S1's Classic Bluetooth serial port (Serial Port Profile), once the printer has been paired in
/// System Settings › Bluetooth. A paired link is authenticated and encrypted: on Linux the kernel listed it as
/// `AUTH ENCRYPT` (notes, 43), and on a Mac the system log reported encryption on every connection (notes, 54).
///
/// The port is opened as an RFCOMM channel of the paired printer, not through the `/dev/cu.PPS1_…` device that
/// macOS also creates. That device reached the printer only the first time it was opened after pairing: later
/// opens succeeded and connected to nothing, until the pairing was removed and made again (notes, 57).
///
/// RFCOMM has its own flow control, so there are no credits to count: one packet is handed to the system at a
/// time, and the next one goes when the system reports that one written.
///
/// Everything here runs on the main thread, where IOBluetooth delivers its callbacks.
final class SerialPort: NSObject, IOBluetoothRFCOMMChannelDelegate {
    enum Event {
        case bytes([UInt8])
        case closed(String)
    }

    /// The printer's Bluetooth address, written as IOBluetooth writes it: six pairs of hex digits joined by `-`.
    let address: String
    private let onEvent: (SerialPort, Event) -> Void
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    /// The channel while it is being opened; `channel` only once the system reports it open.
    private var pending: IOBluetoothRFCOMMChannel?
    private var opening: ((String?) -> Void)?
    private var openTimer: Timer?

    private final class Write {
        let bytes: [UInt8]
        var done = 0
        let completion: (String?) -> Void
        init(_ bytes: [UInt8], _ completion: @escaping (String?) -> Void) {
            self.bytes = bytes
            self.completion = completion
        }
    }
    private var writes: [Write] = []
    /// The packet the system is sending now. It must stay alive until the system reports it written.
    private var packet: NSMutableData?
    private var packetOwner: Write?
    private var stallTimer: Timer?
    /// Ports closed a moment ago. The system may still call back about them (a channel that opens late, a packet
    /// it still holds, the close itself), so they stay alive for a while.
    private static var closing: Set<SerialPort> = []
    /// The port that is opening or open, by printer address: a late callback about an older port of the same
    /// printer must leave this one alone.
    private static var current: [String: SerialPort] = [:]

    private static let openTimeout: TimeInterval = 12
    private static let stallTimeout: TimeInterval = 15
    private static let serialPortService: BluetoothSDPUUID16 = 0x1101

    init(address: String, onEvent: @escaping (SerialPort, Event) -> Void) {
        self.address = address
        self.onEvent = onEvent
    }

    // MARK: Paired printers

    /// The Bluetooth addresses of the paired printers whose name says S1.
    static func candidates() -> [String] {
        let printers = pairedPrinters()
        for printer in printers {
            if let address = printer.addressString, let name = printer.name, !name.isEmpty { names[address] = name }
        }
        return printers.compactMap { $0.addressString }.sorted()
    }

    /// Names seen in the last listings, so that showing a name does not ask the system again.
    private static var names: [String: String] = [:]

    private static func pairedPrinters() -> [IOBluetoothDevice] {
        let all = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return all.filter { isPrinterName($0.name ?? "") }
    }

    /// A paired S1 is named PPS1_…; PPS1_…_BLE is the same printer's Bluetooth LE name.
    static func isPrinterName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.contains("PPS1") && !upper.hasSuffix("_BLE")
    }

    /// Whether a saved identifier is a Bluetooth address. `open` then refuses any address that is not a paired
    /// printer named like an S1, so nothing else is ever opened.
    static func isCandidate(_ id: String) -> Bool {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 6 && parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
    }

    static func displayName(_ id: String) -> String {
        if let known = names[id] { return known }
        guard isCandidate(id), let name = IOBluetoothDevice(addressString: id)?.name, !name.isEmpty else { return id }
        names[id] = name
        return name
    }

    // MARK: Opening and closing

    /// Connects to the printer, which can take a few seconds. `completion` gets nil on success, or a message.
    func open(completion: @escaping (String?) -> Void) {
        guard channel == nil, opening == nil else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        guard let found = Self.pairedPrinters().first(where: { $0.addressString == address }) else {
            DispatchQueue.main.async { completion("The printer is not paired with this Mac.") }
            return
        }
        device = found
        opening = completion
        Self.current[address] = self
        openTimer = Timer.scheduledTimer(withTimeInterval: Self.openTimeout, repeats: false) { [weak self] _ in
            self?.openFailed("The printer did not connect.")
        }
        // First the Bluetooth connection, then the channel. A channel asked for while the printer is not connected
        // is opened by the system once it connects, and then again on every later connection, long after this
        // port has been closed (seen in the system's own log, notes 57).
        if found.isConnected() {
            openChannelOfConnectedPrinter()
        } else {
            let result = found.openConnection(self)
            if result != kIOReturnSuccess { openFailed(Self.message(result)) }
        }
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard opening != nil, channel == nil, pending == nil else { return }
        guard status == kIOReturnSuccess else {
            openFailed(Self.message(status))
            return
        }
        openChannelOfConnectedPrinter()
    }

    private func openChannelOfConnectedPrinter() {
        guard let device else { return }
        if let id = Self.channelID(of: device) {
            openChannel(id)
        } else {
            // macOS stores the printer's service record when it is paired. Without it, ask the printer.
            let result = device.performSDPQuery(self, uuids: [IOBluetoothSDPUUID(uuid16: Self.serialPortService) as Any])
            if result != kIOReturnSuccess { openFailed(Self.message(result)) }
        }
    }

    private static func channelID(of device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        var id: BluetoothRFCOMMChannelID = 0
        guard let record = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: serialPortService)),
              record.getRFCOMMChannelID(&id) == kIOReturnSuccess else { return nil }
        return id
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard opening != nil, channel == nil, pending == nil else { return }
        guard status == kIOReturnSuccess, let device, let id = Self.channelID(of: device) else {
            openFailed("The printer did not offer its serial port.")
            return
        }
        openChannel(id)
    }

    private func openChannel(_ id: BluetoothRFCOMMChannelID) {
        guard let device else { return }
        var opened: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&opened, withChannelID: id, delegate: self)
        pending = opened
        if result != kIOReturnSuccess { openFailed(Self.message(result)) }
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard let done = opening, let rfcommChannel else {
            // This port gave up or was closed in the meantime. Free the printer, unless a newer port has it:
            // closing here would close that one's connection too.
            if Self.current[address] == nil {
                _ = rfcommChannel?.close()
                _ = rfcommChannel?.getDevice()?.closeConnection()
            }
            return
        }
        guard error == kIOReturnSuccess else {
            openFailed(Self.message(error))
            return
        }
        openTimer?.invalidate()
        openTimer = nil
        opening = nil
        pending = nil
        channel = rfcommChannel
        DispatchQueue.main.async { done(nil) }
    }

    private func openFailed(_ message: String) {
        openTimer?.invalidate()
        openTimer = nil
        guard let done = opening else { return }
        opening = nil
        if Self.current[address] === self { Self.current[address] = nil }
        keepAliveForLateCallbacks()
        _ = pending?.close()
        pending = nil
        _ = device?.closeConnection()
        device = nil
        DispatchQueue.main.async { done(message) }
    }

    /// Closes the channel and the Bluetooth connection under it, so the printer is free for another app or browser:
    /// it accepts one connection at a time.
    func close() {
        shutDown()
    }

    private func shutDown() {
        cancelWrites()
        openTimer?.invalidate()
        openTimer = nil
        opening = nil
        stallTimer?.invalidate()
        stallTimer = nil
        if channel != nil || pending != nil || packet != nil || device != nil { keepAliveForLateCallbacks() }
        if Self.current[address] === self { Self.current[address] = nil }
        let open = channel
        channel = nil
        _ = open?.close()
        _ = pending?.close()
        pending = nil
        _ = device?.closeConnection()
        device = nil
    }

    private func keepAliveForLateCallbacks() {
        Self.closing.insert(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openTimeout + 5) { Self.closing.remove(self) }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        packet = nil
        packetOwner = nil
        guard rfcommChannel === channel else { return }  // closed here, by `close`
        failWrites("The printer disconnected.")
        shutDown()
        onEvent(self, .closed("The printer disconnected."))
    }

    // MARK: Reading and writing

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        guard rfcommChannel === channel, let data, length > 0 else { return }
        onEvent(self, .bytes([UInt8](UnsafeRawBufferPointer(start: data, count: length))))
    }

    /// Writes all of `data`, or fails. Writes run one after another, in the order they were asked for.
    func send(_ data: Data, completion: @escaping (String?) -> Void) {
        guard channel != nil else {
            DispatchQueue.main.async { completion("The printer disconnected.") }
            return
        }
        writes.append(Write([UInt8](data), completion))
        if stallTimer == nil { watchForStall() }  // also when an older packet is still with the system
        writeNext()
    }

    private func writeNext() {
        guard packet == nil, let open = channel else { return }
        while let first = writes.first, first.done >= first.bytes.count {
            writes.removeFirst()
            DispatchQueue.main.async { first.completion(nil) }
        }
        guard let write = writes.first else {
            stallTimer?.invalidate()
            stallTimer = nil
            return
        }
        let count = min(max(Int(open.getMTU()), 1), write.bytes.count - write.done)
        let piece = NSMutableData(bytes: Array(write.bytes[write.done..<write.done + count]), length: count)
        packet = piece
        packetOwner = write
        let result = open.writeAsync(piece.mutableBytes, length: UInt16(count), refcon: nil)
        guard result == kIOReturnSuccess else {
            packet = nil
            packetOwner = nil
            let message = "The printer disconnected (\(Self.message(result)))."
            failWrites(message)
            shutDown()
            onEvent(self, .closed(message))
            return
        }
        watchForStall()
    }

    func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        guard let piece = packet else { return }
        let owner = packetOwner
        packet = nil
        packetOwner = nil
        guard rfcommChannel === channel else { return }
        guard error == kIOReturnSuccess else {
            let message = "The printer disconnected (\(Self.message(error)))."
            failWrites(message)
            shutDown()
            onEvent(self, .closed(message))
            return
        }
        // A write dropped by `cancelWrites` while its packet was out is no longer first in the list.
        if let owner, writes.first === owner {
            owner.done += piece.length
            if owner.done >= owner.bytes.count {
                writes.removeFirst()
                DispatchQueue.main.async { owner.completion(nil) }
            }
        }
        writeNext()
    }

    /// The printer takes no more data when it is out of paper or its lid is open: the system then never reports
    /// the packet written.
    private func watchForStall() {
        stallTimer?.invalidate()
        stallTimer = Timer.scheduledTimer(withTimeInterval: Self.stallTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.stallTimer = nil
            if !self.writes.isEmpty { self.failWrites("The printer stopped accepting data. Check the paper and the lid.") }
        }
    }

    private func failWrites(_ message: String) {
        stallTimer?.invalidate()
        stallTimer = nil
        let failed = writes
        writes = []
        // Later, not now: the caller cancels writes while it is finishing a job, and must not be called back
        // in the middle of that.
        if !failed.isEmpty { DispatchQueue.main.async { for write in failed { write.completion(message) } } }
    }

    /// Writes still waiting are dropped. A packet already with the system, at most one, cannot be taken back.
    func cancelWrites() {
        failWrites("Cancelled.")
    }

    /// Calls back once nothing is left to hand to the system, with `false` if something was still waiting after
    /// `limit`. The system reports a packet written when it has sent it, not when the printer has printed it.
    func waitUntilSent(limit: TimeInterval, completion: @escaping (Bool) -> Void) {
        let end = Date().addingTimeInterval(limit)
        func check() {
            if channel == nil || (writes.isEmpty && packet == nil) { completion(true) }
            else if Date() >= end { completion(false) }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { check() } }
        }
        DispatchQueue.main.async { check() }
    }

    /// Drops what has not been handed to the system yet, so a failed job does not run into the next one.
    func discardOutput() {
        cancelWrites()
    }

    private static func message(_ result: IOReturn) -> String {
        String(format: "Bluetooth error 0x%08X", UInt32(bitPattern: result))
    }
}
