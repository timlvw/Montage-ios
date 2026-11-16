import Foundation
import CoreBluetooth

/// Bluetooth LE central for the MiniGauge: finds it by its service, connects,
/// subscribes to the live frames and text replies, and reconnects by itself
/// (a pending connect never times out on iOS, so the phone picks the gauge up
/// again as soon as it is powered, even with the app in the background).
final class GaugeLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var store: GaugeStore?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var text = TextReassembler()
    private var wanted = false

    private let svcID = CBUUID(string: GaugeUUID.service)
    private let liveID = CBUUID(string: GaugeUUID.live)
    private let cmdID = CBUUID(string: GaugeUUID.command)
    private let textID = CBUUID(string: GaugeUUID.text)
    private let savedKey = "gauge.peripheral"

    var isReady: Bool { cmdChar != nil && peripheral?.state == .connected }

    func start() {
        wanted = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionRestoreIdentifierKey: "MiniGaugeCentral",
                                                 CBCentralManagerOptionShowPowerAlertKey: true])
        } else {
            connectOrScan()
        }
    }

    func stop() {
        wanted = false
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        store?.setConn(.idle)
    }

    /// Forget the saved gauge and look for any MiniGauge.
    func forget() {
        UserDefaults.standard.removeObject(forKey: savedKey)
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        cmdChar = nil
        connectOrScan()
    }

    @discardableResult
    func send(_ command: String) -> Bool {
        guard let p = peripheral, p.state == .connected, let c = cmdChar, let d = command.data(using: .utf8) else { return false }
        p.writeValue(d, for: c, type: .withResponse)
        return true
    }

    // MARK: - connecting

    private func use(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
    }

    private func connectOrScan() {
        guard wanted, let c = central, c.state == .poweredOn else { return }
        if let p = peripheral {
            switch p.state {
            case .connected:
                if cmdChar == nil { p.discoverServices([svcID]) }
                return
            case .connecting:
                return
            default:
                c.connect(p, options: nil)
                store?.setConn(.connecting)
            }
        } else if let p = c.retrieveConnectedPeripherals(withServices: [svcID]).first {
            use(p)
            c.connect(p, options: nil)
            store?.setConn(.connecting)
        } else if let s = UserDefaults.standard.string(forKey: savedKey), let id = UUID(uuidString: s),
                  let p = c.retrievePeripherals(withIdentifiers: [id]).first {
            use(p)
            c.connect(p, options: nil)
            store?.setConn(.connecting)
        }
        // Scan as well: finds a different board, or the same one if iOS has
        // forgotten it. Stopped as soon as something connects.
        if peripheral?.state != .connected {
            c.scanForPeripherals(withServices: [svcID], options: nil)
            if peripheral == nil { store?.setConn(.scanning) }
        }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: connectOrScan()
        case .poweredOff: store?.setConn(.bluetoothOff)
        case .unauthorized: store?.setConn(.unauthorized)
        case .unsupported: store?.setConn(.unsupported)
        default: break
        }
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        wanted = true
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first {
            use(p)
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        if let cur = peripheral, cur.identifier != p.identifier, cur.state == .connected { return }
        if let cur = peripheral, cur.identifier != p.identifier { c.cancelPeripheralConnection(cur) }
        use(p)
        c.connect(p, options: nil)
        store?.setConn(.connecting)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        c.stopScan()
        UserDefaults.standard.set(p.identifier.uuidString, forKey: savedKey)
        store?.deviceName = p.name ?? "MiniGauge"
        text = TextReassembler()
        p.discoverServices([svcID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if wanted { c.connect(p, options: nil) }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        cmdChar = nil
        store?.linkDropped()
        guard wanted, p.identifier == peripheral?.identifier else { return }
        c.connect(p, options: nil)          // waits until the gauge is back
        store?.setConn(.connecting)
    }

    // MARK: - GATT

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == svcID }) else { return }
        p.discoverCharacteristics([liveID, cmdID, textID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == liveID || ch.uuid == textID { p.setNotifyValue(true, for: ch) }
            if ch.uuid == cmdID { cmdChar = ch }
        }
        store?.setConn(.connected)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        // Replies only flow once TEXT is subscribed: ask for the set-up then.
        if ch.uuid == textID && ch.isNotifying { store?.linkReady() }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard error == nil, let d = ch.value else { return }
        let bytes = [UInt8](d)
        if ch.uuid == liveID {
            if let f = try? FrameDecoder.decode(bytes) { store?.ingest(f) }
        } else if ch.uuid == textID {
            if let r = text.feed(bytes) { store?.reply(r.text) }
        }
    }
}
