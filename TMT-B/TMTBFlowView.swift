import SwiftUI
import Combine

// MARK: - Modelos

struct Stimulus: Identifiable, Equatable {
    let id: Int            // índice en la secuencia (0 = inicio)
    let label: String      // "1", "A", "2", "B", ...
    let center: CGPoint    // posición en puntos dentro del lienzo
}

enum TMTBPhase {
    case instructions, practice, officialNotice, official, finished
}

/// Una interacción del participante (o evento de la app) guardada en el JSON.
struct TMTBEvent: Codable {
    let type: String              // ej. "error_secuencia", "conexion_correcta"
    let timestamp: Date           // fecha y hora exacta
    let phase: String             // "practica" u "oficial"
    let elapsedSeconds: Double?   // segundos desde el primer toque (nil antes de empezar)
    let from: String?             // último nodo correcto
    let to: String?               // nodo tocado
    let expected: String?         // nodo que correspondía
    let detail: String            // descripción legible, ej. "Se equivocó: tocó «B» pero debía tocar «2»"
}

struct PhaseSummary: Codable {
    let phase: String
    let totalTimeSeconds: Double
    let errors: Int
    let interruptions: Int
    let correctConnections: Int
    let events: [TMTBEvent]
}

struct TMTBResult: Codable {
    let date: Date
    let practice: PhaseSummary?
    let official: PhaseSummary
}

// MARK: - Generación de estímulos

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum TMTBSequence {
    /// 8 estímulos de práctica: 1-A-2-B-3-C-4-D. 25 oficiales: 1-A-2-B-...-12-L-13
    static func labels(count: Int) -> [String] {
        let letters = "ABCDEFGHIJKL".map(String.init)
        return (0..<count).map { i in i % 2 == 0 ? "\(i / 2 + 1)" : letters[i / 2] }
    }

    /// Devuelve nil si no logra acomodar los estímulos (→ botón "Volver a cargar").
    static func makeStimuli(count: Int, size: CGSize, seed: UInt64) -> [Stimulus]? {
        guard size.width > 120, size.height > 120 else { return nil }
        var rng = SeededRNG(state: seed)
        let margin: CGFloat = 36
        let minDist = min(size.width, size.height) * (count > 10 ? 0.14 : 0.30)
        var points: [CGPoint] = []
        var attempts = 0
        while points.count < count && attempts < 20_000 {
            attempts += 1
            let p = CGPoint(
                x: .random(in: margin...(size.width - margin), using: &rng),
                y: .random(in: margin...(size.height - margin), using: &rng)
            )
            if points.allSatisfy({ hypot($0.x - p.x, $0.y - p.y) >= minDist }) {
                points.append(p)
            }
        }
        guard points.count == count else { return nil }
        let labels = Self.labels(count: count)
        return (0..<count).map { Stimulus(id: $0, label: labels[$0], center: points[$0]) }
    }
}

// MARK: - ViewModel

@MainActor
final class TMTBViewModel: ObservableObject {
    static let practiceCount = 8
    static let officialCount = 25
    static let hitRadius: CGFloat = 30

    @Published var phase: TMTBPhase = .instructions
    @Published var stimuli: [Stimulus] = []
    @Published var connectedCount = 0
    @Published var fingerPoint: CGPoint?
    @Published var tracing = false
    @Published var message = ""
    @Published var wrongId: Int?     // nodo equivocado (parpadea en rojo)
    @Published var hintId: Int?      // nodo correcto siguiente (solo práctica)
    @Published var returnId: Int?    // último nodo correcto al que se regresa
    @Published var loadFailed = false
    @Published var errorCount = 0
    @Published var interruptions = 0
    @Published var totalTime: Double = 0

    // Verificación del guardado
    @Published var savedURL: URL?
    @Published var saveStatus = ""   // solo para la consola del investigador

    private var events: [TMTBEvent] = []
    private var practiceSummary: PhaseSummary?
    private var startDate: Date?
    private var gestureActive = false

    private var phaseName: String { phase == .practice ? "practica" : "oficial" }

    // MARK: Flujo

    func go(_ newPhase: TMTBPhase) {
        phase = newPhase
        resetRun()
        switch newPhase {
        case .practice:
            log("boton_continuar", detail: "Presionó «Continuar» en las instrucciones")
        case .official:
            log("boton_aceptar", detail: "Presionó «Aceptar» en el aviso de la prueba oficial")
        default:
            break
        }
    }

    private func resetRun() {
        stimuli = []
        connectedCount = 0
        tracing = false
        fingerPoint = nil
        message = ""
        wrongId = nil
        hintId = nil
        returnId = nil
        errorCount = 0
        interruptions = 0
        events = []
        startDate = nil
        gestureActive = false
        loadFailed = false
    }

    func load(size: CGSize) {
        let count = phase == .practice ? Self.practiceCount : Self.officialCount
        let seed: UInt64 = phase == .practice ? 7 : 2026   // misma disposición para todos
        if let s = TMTBSequence.makeStimuli(count: count, size: size, seed: seed) {
            stimuli = s
            loadFailed = false
            log("estimulos_cargados", detail: "Se cargaron \(count) estímulos")
        } else {
            stimuli = []
            loadFailed = true
            log("error_carga", detail: "No se pudieron cargar los estímulos")
        }
    }

    // MARK: Bitácora

    private func log(_ type: String,
                     from: String? = nil,
                     to: String? = nil,
                     expected: String? = nil,
                     detail: String) {
        events.append(TMTBEvent(type: type,
                                timestamp: Date(),
                                phase: phaseName,
                                elapsedSeconds: elapsedNow(),
                                from: from,
                                to: to,
                                expected: expected,
                                detail: detail))
    }

    private func makeSummary() -> PhaseSummary {
        PhaseSummary(phase: phaseName,
                     totalTimeSeconds: elapsedNow() ?? 0,
                     errors: errorCount,
                     interruptions: interruptions,
                     correctConnections: max(connectedCount - 1, 0),
                     events: events)
    }

    // MARK: Gestos

    func dragChanged(_ p: CGPoint) {
        if !gestureActive {
            gestureActive = true
            touchBegan(at: p)
        } else {
            touchMoved(at: p)
        }
    }

    func dragEnded() {
        if tracing && !stimuli.isEmpty {
            // El participante levantó el dedo a mitad del trazo
            tracing = false
            fingerPoint = nil
            interruptions += 1
            let last = stimuli[connectedCount - 1]
            returnId = last.id
            message = "Levantaste el dedo. Toca «\(last.label)» para continuar."
            log("dedo_levantado",
                from: last.label,
                detail: "Levantó el dedo después de «\(last.label)»; debe reanudar desde ese nodo")
        }
        gestureActive = false
    }

    private func touchBegan(at p: CGPoint) {
        guard !loadFailed, !stimuli.isEmpty, !tracing else { return }
        let target = max(connectedCount - 1, 0)   // inicio, o el último correcto
        let targetLabel = stimuli[target].label
        guard hitIndex(p) == target else {
            log("toque_invalido",
                expected: targetLabel,
                detail: "Tocó fuera del nodo «\(targetLabel)» donde debía \(connectedCount == 0 ? "comenzar" : "reanudar")")
            return
        }
        tracing = true
        fingerPoint = p
        message = ""
        returnId = nil
        if connectedCount == 0 {
            connect(0)
        } else {
            log("reanuda_trazo", from: targetLabel, detail: "Reanudó el trazo desde «\(targetLabel)»")
        }
    }

    private func touchMoved(at p: CGPoint) {
        guard tracing else { return }
        fingerPoint = p
        guard let hit = hitIndex(p) else { return }
        if hit == connectedCount {
            connect(hit)
        } else if hit > connectedCount {
            registerError(touched: hit)
        }
        // hit <= connectedCount - 1: ya conectado, se ignora
    }

    // MARK: Lógica

    private func connect(_ i: Int) {
        if i == 0 && startDate == nil {
            startDate = Date()           // el cronómetro inicia al tocar el primer estímulo
        }
        if i == 0 {
            log("inicio_trazo", to: stimuli[0].label,
                detail: "Tocó el nodo de inicio «\(stimuli[0].label)»")
        } else {
            log("conexion_correcta",
                from: stimuli[i - 1].label,
                to: stimuli[i].label,
                detail: "Conectó «\(stimuli[i - 1].label)» con «\(stimuli[i].label)»")
        }
        connectedCount = i + 1
        wrongId = nil
        hintId = nil
        returnId = nil
        if connectedCount == stimuli.count { finishRun() }
    }

    private func registerError(touched hit: Int) {
        errorCount += 1
        let last = stimuli[connectedCount - 1]
        let expected = stimuli[connectedCount]
        let touched = stimuli[hit]

        log("error_secuencia",
            from: last.label,
            to: touched.label,
            expected: expected.label,
            detail: "Se equivocó: tocó «\(touched.label)» pero debía tocar «\(expected.label)»")

        // Se retrae la línea: solo queda el trazo hasta el último nodo correcto
        tracing = false
        fingerPoint = nil
        wrongId = hit
        returnId = last.id

        log("retorno_ultimo_correcto",
            to: last.label,
            detail: "La línea se retrajo al último nodo correcto «\(last.label)»")

        if phase == .practice {
            hintId = expected.id
            message = "Error: después de «\(last.label)» sigue «\(expected.label)», no «\(touched.label)». Vuelve a tocar «\(last.label)» para continuar."
        } else {
            message = "Error. Vuelve a tocar «\(last.label)» para continuar."
        }

        let id = hit
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if wrongId == id { wrongId = nil }
        }
    }

    private func finishRun() {
        tracing = false
        fingerPoint = nil
        log("secuencia_completada", detail: "Conectó todos los estímulos de la \(phase == .practice ? "práctica" : "prueba oficial")")
        if phase == .practice {
            practiceSummary = makeSummary()
            phase = .officialNotice
            return
        }
        let summary = makeSummary()
        totalTime = summary.totalTimeSeconds
        save(TMTBResult(date: Date(), practice: practiceSummary, official: summary))
        phase = .finished
    }

    private func elapsedNow() -> Double? {
        startDate.map { Date().timeIntervalSince($0) }
    }

    private func hitIndex(_ p: CGPoint) -> Int? {
        stimuli.firstIndex { hypot($0.center.x - p.x, $0.center.y - p.y) <= Self.hitRadius }
    }

    // MARK: Persistencia local (JSON) + verificación

    private func save(_ result: TMTBResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = docs.appendingPathComponent("tmtb_\(Int(Date().timeIntervalSince1970)).json")
            try encoder.encode(result).write(to: url, options: .atomic)

            // Verificación: se lee el archivo del disco y se decodifica de nuevo
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let check = try decoder.decode(TMTBResult.self, from: data)

            savedURL = url
            saveStatus = "✓ Guardado y verificado (\(check.official.events.count) eventos en la prueba oficial)"
            print("TMT-B \(saveStatus)")
            print("TMT-B JSON guardado en: \(url.path)")
        } catch {
            saveStatus = "⚠️ No se pudo guardar: \(error.localizedDescription)"
            print("TMT-B error al guardar: \(error)")
        }
    }
}

// MARK: - Vistas

struct TMTBFlowView: View {
    @StateObject private var vm = TMTBViewModel()
    /// Se llama al terminar para pasar al siguiente caso de uso.
    var onFinish: (URL?) -> Void = { _ in }

    var body: some View {
        switch vm.phase {
        case .instructions:
            InfoScreen(
                title: "TMT-B: Práctica",
                text: """
                Verás círculos con números y letras. Conéctalos en orden alternando \
                número y letra: 1 → A → 2 → B → 3 → C …

                Toca el círculo de inicio y traza una línea sin levantar el dedo. \
                Si te equivocas, la línea se retrae y volverás al último círculo correcto.

                Primero harás una práctica corta.
                """,
                button: "Continuar"
            ) { vm.go(.practice) }

        case .practice, .official:
            TMTBCanvasScreen(vm: vm)

        case .officialNotice:
            InfoScreen(
                title: "Prueba oficial",
                text: "Ahora comenzará la prueba real. Trabaja lo más rápido que puedas sin cometer errores. El tiempo empieza al tocar el primer círculo.",
                button: "Aceptar"
            ) { vm.go(.official) }

        case .finished:
            // El participante no ve resultados: el JSON ya se guardó en segundo plano.
            VStack(spacing: 24) {
                Text("Prueba finalizada").font(.largeTitle.bold())
                Text("Gracias por tu participación.").font(.title3)
                Button("Siguiente") { onFinish(vm.savedURL) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(32)
        }
    }
}

struct InfoScreen: View {
    let title: String
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text(title).font(.largeTitle.bold())
            Text(text).font(.title3)
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
    }
}

struct TMTBCanvasScreen: View {
    @ObservedObject var vm: TMTBViewModel

    var body: some View {
        VStack(spacing: 8) {
            Text(vm.phase == .practice ? "Práctica" : "Prueba oficial")
                .font(.headline)
            Text(vm.message)
                .font(.subheadline)
                .foregroundStyle(.red)
                .frame(minHeight: 44)
                .padding(.horizontal)

            GeometryReader { geo in
                ZStack {
                    Color(white: 0.97)

                    if vm.loadFailed {
                        VStack(spacing: 12) {
                            Text("No se pudieron cargar los estímulos")
                            Button("Volver a cargar") { vm.load(size: geo.size) }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        // Línea del trazo (solo tramos correctos + dedo)
                        Path { path in
                            let pts = vm.stimuli.prefix(vm.connectedCount).map(\.center)
                            guard let first = pts.first else { return }
                            path.move(to: first)
                            pts.dropFirst().forEach { path.addLine(to: $0) }
                            if vm.tracing, let f = vm.fingerPoint { path.addLine(to: f) }
                        }
                        .stroke(Color.blue,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

                        ForEach(vm.stimuli) { s in
                            StimulusView(stimulus: s,
                                         isStart: s.id == 0,
                                         isEnd: vm.phase == .practice && s.id == vm.stimuli.count - 1,
                                         isConnected: s.id < vm.connectedCount,
                                         isWrong: vm.wrongId == s.id,
                                         isHint: vm.hintId == s.id,
                                         isReturn: vm.returnId == s.id)
                                .position(s.center)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { vm.dragChanged($0.location) }
                        .onEnded { _ in vm.dragEnded() }
                )
                .onAppear { vm.load(size: geo.size) }
            }
        }
    }
}

struct StimulusView: View {
    let stimulus: Stimulus
    let isStart: Bool
    let isEnd: Bool
    let isConnected: Bool
    let isWrong: Bool
    let isHint: Bool      // nodo correcto que seguía (práctica)
    let isReturn: Bool    // último nodo correcto al que se regresó

    private var fill: Color {
        if isWrong { return .red.opacity(0.35) }
        if isStart { return .green.opacity(0.35) }
        if isEnd { return .orange.opacity(0.35) }
        if isConnected { return .blue.opacity(0.15) }
        return .white
    }

    private var ringColor: Color {
        if isHint { return .green }
        if isReturn { return .purple }
        return .black
    }

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Circle().stroke(ringColor,
                            lineWidth: isHint || isReturn || isStart || isEnd ? 4 : 2)
            Text(stimulus.label).font(.headline).foregroundStyle(.black)
            if isStart {
                Text("INICIO").font(.caption2.bold()).foregroundStyle(.green)
                    .offset(y: -34)
            }
            if isEnd {
                Text("FIN").font(.caption2.bold()).foregroundStyle(.orange)
                    .offset(y: -34)
            }
        }
        .frame(width: 48, height: 48)
    }
}

#Preview {
    TMTBFlowView()
}
