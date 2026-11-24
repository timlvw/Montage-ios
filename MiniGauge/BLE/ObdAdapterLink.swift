import Foundation
import CoreBluetooth

/// Bluetooth LE central for an ELM327 OBD adapter, used instead of the gauge
/// ("Connect to: OBD adapter" in Settings). Finds the adapter (clones
/// advertise all sorts, so it goes by name and service hints, like the gauge
/// firmware's ble_obd.cpp), picks its notify/write pair, then hands the
/// ELM327 conversation to ElmSession and the readings to DirectData.
final class ObdAdapterLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var store: GaugeStore?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    private var pendingServices = 0
    private var wanted = false
    private var rx = ""
    private var timeoutWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var publishTimer: Timer?
    private var session: ElmSession?
    private var data = DirectData()
    private var lastInfoPids: Set<UInt8> = []
    private var codesAsked = false
    private var lastInfoUnits = ""

    private let savedKey = "adapter.peripheral"
    private let protoKey = "adapter.protocol"
    private let gaugeService = CBUUID(string: GaugeUUID.service)

    var isConnected: Bool { peripheral?.state == .connected && writeChar != nil }

    func start() {
        wanted = true
        data.clear()
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionRestoreIdentifierKey: "MiniGaugeAdapterCentral",
                                                 CBCentralManagerOptionShowPowerAlertKey: true])
        } else {
            connectOrScan()
        }
        publishTimer?.invalidate()
        publishTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.publishSlow() }
    }

    func stop() {
        wanted = false
        publishTimer?.invalidate()
        publishTimer = nil
        timeoutWork?.cancel()
        retryWork?.cancel()
        session?.stop()
        session = nil
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
    }

    /// Forget the saved adapter and look for any.
    func forget() {
        UserDefaults.standard.removeObject(forKey: savedKey)
        UserDefaults.standard.removeObject(forKey: protoKey)
        session?.stop()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        notifyChar = nil
        writeChar = nil
        connectOrScan()
    }

    // MARK: - requests from the app

    func readCodes(done: @escaping (Result<[String], ElmError>) -> Void) {
        guard let s = session else { done(.failure(.unableToConnect)); return }
        s.request("03") { r in
            switch r {
            case .success(let lines): done(.success(ObdDecode.codes(lines)))
            case .failure(.noData): done(.success([]))            // nothing stored
            case .failure(let e): done(.failure(e))
            }
        }
    }

    func clearCodes(done: @escaping (ElmError?) -> Void) {
        guard let s = session else { done(.unableToConnect); return }
        s.request("04") { r in
            switch r {
            case .success, .failure(.noData): done(nil)
            case .failure(let e): done(e)
            }
        }
    }

    // MARK: - units for the frames (the gauge's, when it last told us)

    private func applyUnits() {
        let d = UserDefaults.standard
        data.tempF = d.object(forKey: "lastUnits.tempF") as? Bool ?? true
        data.mph = d.object(forKey: "lastUnits.mph") as? Bool ?? true
        data.psi = d.object(forKey: "lastUnits.psi") as? Bool ?? false
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
            case .connected: if writeChar == nil { p.discoverServices(nil) }; return
            case .connecting: return
            default:
                c.connect(p, options: nil)
                store?.setConn(.connecting)
                return
            }
        }
        if let s = UserDefaults.standard.string(forKey: savedKey), let id = UUID(uuidString: s),
           let p = c.retrievePeripherals(withIdentifiers: [id]).first {
            use(p)
            c.connect(p, options: nil)
            store?.setConn(.connecting)
            return
        }
        // Clones often advertise no services, so scan for everything and
        // pick by name / service hints.
        c.scanForPeripherals(withServices: nil, options: nil)
        store?.setConn(.scanning)
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
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first { use(p) }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard peripheral == nil || peripheral?.state != .connected else { return }
        let svcs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
        if svcs.contains(gaugeService) { return }                     // that's the gauge itself
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name
        guard AdapterAdvert.plausible(name: name, services: svcs.map(\.uuidString), rssi: rssi.intValue) else { return }
        c.stopScan()
        use(p)
        c.connect(p, options: nil)
        store?.setConn(.connecting)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        c.stopScan()
        store?.deviceName = p.name ?? "OBD adapter"
        notifyChar = nil
        writeChar = nil
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if wanted { c.connect(p, options: nil) }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        timeoutWork?.cancel()
        retryWork?.cancel()
        session?.stop()
        session = nil
        notifyChar = nil
        writeChar = nil
        data.clear()
        guard wanted else { return }            // stopped: the gauge link may be in charge now
        store?.linkDropped()
        guard p.identifier == peripheral?.identifier else { return }
        c.connect(p, options: nil)          // waits until the adapter is back (plugged in, car woken)
        store?.setConn(.connecting)
    }

    // MARK: - GATT: find the notify / write pair

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let svcs = p.services ?? []
        pendingServices = svcs.count
        if svcs.isEmpty { giveUp(p) }
        for s in svcs { p.discoverCharacteristics(nil, for: s) }
    }

    private func giveUp(_ p: CBPeripheral) {     // nothing usable: try again from scratch
        central?.cancelPeripheralConnection(p)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        pendingServices -= 1
        guard pendingServices <= 0 else { return }
        guard let pair = Self.pickPair(p.services ?? []) else {
            store?.lastNoticeFromLink("That device has no OBD adapter connection. Forget it in Settings to search again.")
            giveUp(p)
            return
        }
        notifyChar = pair.0
        writeChar = pair.1
        p.setNotifyValue(true, for: pair.0)
    }

    /// Prefer the classic clone pair (FFF1 notify, FFF2 write), then FFE1,
    /// then 18F0's, then any notify + write in the same service.
    static func pickPair(_ services: [CBService]) -> (CBCharacteristic, CBCharacteristic)? {
        func chars(_ s: CBService) -> [CBCharacteristic] { s.characteristics ?? [] }
        func canNotify(_ c: CBCharacteristic) -> Bool { c.properties.contains(.notify) || c.properties.contains(.indicate) }
        func canWrite(_ c: CBCharacteristic) -> Bool { c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) }
        let all = services.flatMap(chars)
        func find(_ u: String) -> CBCharacteristic? { all.first { $0.uuid.uuidString.uppercased() == u } }
        if let n = find("FFF1"), canNotify(n), let w = find("FFF2"), canWrite(w) { return (n, w) }
        if let c = find("FFE1"), canNotify(c), canWrite(c) { return (c, c) }
        if let n = find("2AF0"), canNotify(n), let w = find("2AF1"), canWrite(w) { return (n, w) }
        for s in services where s.uuid != CBUUID(string: GaugeUUID.service) {
            if let n = chars(s).first(where: canNotify), let w = chars(s).first(where: canWrite) { return (n, w) }
        }
        return nil
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard ch == notifyChar, ch.isNotifying else { return }
        UserDefaults.standard.set(p.identifier.uuidString, forKey: savedKey)
        store?.setConn(.connected)
        startSession()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard error == nil, ch == notifyChar, let d = ch.value else { return }
        rx += String(decoding: d.filter { $0 != 0 }, as: UTF8.self)
        while let r = rx.firstIndex(of: ">") {
            let reply = String(rx[..<r])
            rx = String(rx[rx.index(after: r)...])
            timeoutWork?.cancel()
            session?.received(reply)
        }
        if rx.count > 4096 { rx = "" }       // runaway: no prompt in sight
    }

    // MARK: - the ELM327 session

    private func startSession() {
        applyUnits()
        data.clear()
        rx = ""
        let s = ElmSession(protocolFirst: UserDefaults.standard.string(forKey: protoKey))
        s.send = { [weak self] cmd, timeout in self?.write(cmd, timeout: timeout) }
        s.gotValue = { [weak self] pid, v in self?.value(pid, v) }
        codesAsked = false
        s.gotStatus = { [weak self] mil, n in
            guard let self = self else { return }
            self.data.mil = mil
            self.data.dtcCount = n
            if n > 0 && self.data.codes.isEmpty && !self.codesAsked {      // the Car tab lists them without a tap
                self.codesAsked = true
                self.readCodes { if case .success(let c) = $0 { self.setCodes(c) } }
            }
            if n == 0 && !self.data.codes.isEmpty { self.data.codes = [] }
        }
        s.stateChanged = { [weak self] st in self?.sessionState(st) }
        s.retryLater = { [weak self] t in
            guard let self = self else { return }
            self.retryWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.session?.resume() }
            self.retryWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
        }
        s.adapterDead = { [weak self] in
            guard let self = self, let p = self.peripheral else { return }
            self.central?.cancelPeripheralConnection(p)          // reconnects by itself
        }
        s.protocolWorked = { p in UserDefaults.standard.set(p, forKey: "adapter.protocol") }
        session = s
        s.start()
    }

    private func write(_ cmd: String, timeout: TimeInterval) {
        guard let p = peripheral, p.state == .connected, let w = writeChar, let d = (cmd + "\r").data(using: .ascii) else { return }
        rx = ""
        p.writeValue(d, for: w, type: w.properties.contains(.write) ? .withResponse : .withoutResponse)
        timeoutWork?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.session?.timedOut() }
        timeoutWork = t
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: t)
    }

    private func sessionState(_ st: ElmSession.State) {
        data.linkText = "Direct to \(store?.deviceName ?? "the OBD adapter"): " + st.text
        if case .running = st { data.running = true } else { data.running = false; data.clear() }
        publishSlow()
    }

    private func value(_ pid: UInt8, _ v: Double) {
        let now = Date()
        data.add(pid, v, at: now)
        guard DirectData.field(pid) != nil else { return }
        store?.ingest(.engine(data.engineFrame(at: now)))
    }

    /// Gauges, status and (when it changes) the set-up, twice a second.
    private func publishSlow() {
        guard let store = store, wanted else { return }
        let now = Date()
        applyUnits()
        guard isConnected else { return }       // linkDropped() has said so already
        data.limit = store.limitForFrames
        let pids = Set(data.latest.keys)
        let units = "\(data.tempF)\(data.mph)\(data.psi)" + (data.limit.map { "\($0.kmh)\($0.settings.amberOverKmh)\($0.settings.redOverKmh)\($0.settings.amberAlarm)\($0.settings.redAlarm)" } ?? "")
        if pids != lastInfoPids || units != lastInfoUnits || store.info == nil {
            lastInfoPids = pids
            lastInfoUnits = units
            store.setDirectInfo(data.info())
        }
        store.ingest(.gauges(data.slots(at: now)))
        store.ingest(.status(data.status(at: now)))
        if data.latest.isEmpty { store.ingest(.engine(data.engineFrame(at: now))) }
    }

    /// Codes read: kept for the status frame (the Car tab lists them).
    func setCodes(_ c: [String]) {
        data.codes = c
        data.dtcCount = c.count
        publishSlow()
    }
}
