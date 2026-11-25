import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var login: LoginItem

    var body: some View {
        VStack(spacing: 6) {
            TabView {
                GeneralSettings(login: login).tabItem { Label("General", systemImage: "gearshape") }
                GestureSettings().tabItem { Label("Gestos", systemImage: "hand.draw") }
                MusicSettings().tabItem { Label("Música", systemImage: "music.note") }
                ActivitySettings().tabItem { Label("Actividades", systemImage: "sparkles") }
                HUDSettings().tabItem { Label("Avisos", systemImage: "speaker.wave.2") }
                CalendarSettings().tabItem { Label("Calendario", systemImage: "calendar") }
            }
            Text("Hecho por Mediiinaaa")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 6)
        }
        .frame(width: 560, height: 520)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var login: LoginItem
    @AppStorage(Preference.keepAwake) private var keepAwake = false
    @AppStorage(Preference.hideInFullscreen) private var hideInFullscreen = false
    @AppStorage(Preference.hideFromCapture) private var hideFromCapture = false
    @AppStorage(Preference.forceSimulatedNotch) private var simulatedNotch = false
    @AppStorage(Preference.notchWidthOffset) private var widthOffset = 0.0
    @AppStorage(Preference.notchHeightOffset) private var heightOffset = 0.0

    var body: some View {
        Form {
            Section {
                Toggle("Abrir al iniciar sesión", isOn: $login.isEnabled)
                if let error = login.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Toggle("Mantener el Mac despierto", isOn: $keepAwake)
            }
            Section("Pantalla") {
                Toggle("Ocultar en pantalla completa", isOn: $hideInFullscreen)
                Toggle("Ocultar en capturas de pantalla", isOn: $hideFromCapture)
                Toggle("Forzar notch simulado", isOn: $simulatedNotch)
            }
            Section("Ajuste del notch") {
                Slider(value: $widthOffset, in: -40...40) { Text("Ancho") }
                Slider(value: $heightOffset, in: -10...10) { Text("Alto") }
                Button("Restablecer") {
                    widthOffset = 0
                    heightOffset = 0
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct GestureSettings: View {
    @AppStorage(Preference.expandOnHover) private var expandOnHover = true
    @AppStorage(Preference.hoverDuration) private var hoverDuration = 0.1
    @AppStorage(Preference.tapToExpand) private var tapToExpand = true
    @AppStorage(Preference.swipeToSkip) private var swipeToSkip = true
    @AppStorage(Preference.swipeToToggle) private var swipeToToggle = true
    @AppStorage(Preference.haptics) private var haptics = true

    var body: some View {
        Form {
            Section("Abrir") {
                Toggle("Desplegar al pasar el ratón", isOn: $expandOnHover)
                Slider(value: $hoverDuration, in: 0...1, step: 0.05) { Text("Espera") }
                    .disabled(!expandOnHover)
                Toggle("Desplegar al hacer clic", isOn: $tapToExpand)
            }
            Section("Con dos dedos sobre la isla") {
                Toggle("Deslizar en horizontal para cambiar de canción", isOn: $swipeToSkip)
                Toggle("Deslizar en vertical para abrir o cerrar", isOn: $swipeToToggle)
            }
            Section {
                Toggle("Respuesta háptica", isOn: $haptics)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MusicSettings: View {
    @AppStorage(Preference.showMusic) private var showMusic = true
    @AppStorage(Preference.peekOnChange) private var peekOnChange = true
    @AppStorage(Preference.peekDuration) private var peekDuration = 2.5
    @AppStorage(Preference.useArtworkColor) private var useArtworkColor = true
    @AppStorage(Preference.showLyrics) private var showLyrics = true

    var body: some View {
        Form {
            Section {
                Toggle("Mostrar la música en reproducción", isOn: $showMusic)
                Toggle("Vistazo al cambiar de canción", isOn: $peekOnChange)
                Slider(value: $peekDuration, in: 1...6, step: 0.5) { Text("Duración") }
                    .disabled(!peekOnChange)
                Toggle("Usar el color de la carátula", isOn: $useArtworkColor)
                Toggle("Mostrar la letra sincronizada", isOn: $showLyrics)
            } header: {
                Text("En la isla")
            } footer: {
                Text("Las letras vienen de LRCLIB, una base de datos abierta: para buscarlas se envían el título, el artista y la duración de la canción.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ActivitySettings: View {
    @AppStorage(Preference.showPower) private var showPower = true
    @AppStorage(Preference.warnLowBattery) private var warnLowBattery = true
    @AppStorage(Preference.lowBatteryThreshold) private var threshold = 20
    @AppStorage(Preference.notifyLowPower) private var notifyLowPower = true
    @AppStorage(Preference.soundLowBattery) private var soundLowBattery = true
    @AppStorage(Preference.showOutput) private var showOutput = true
    @AppStorage(Preference.hourlyChime) private var hourlyChime = false

    var body: some View {
        Form {
            Section("Batería") {
                Toggle("Cargador conectado o desconectado", isOn: $showPower)
                Toggle("Avisar con batería baja", isOn: $warnLowBattery)
                Stepper("Umbral: \(threshold) %", value: $threshold, in: 5...50, step: 5)
                    .disabled(!warnLowBattery)
                Toggle("Sonido con batería baja", isOn: $soundLowBattery)
                Toggle("Avisar al activar el modo de ahorro", isOn: $notifyLowPower)
            }
            Section("Otros") {
                Toggle("Cambio de auriculares o altavoz", isOn: $showOutput)
                Toggle("Sonido cada hora en punto", isOn: $hourlyChime)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HUDSettings: View {
    @AppStorage(Preference.showVolume) private var showVolume = true
    @AppStorage(Preference.showPercentage) private var showPercentage = false
    @AppStorage(Preference.replaceSystemHUD) private var replaceSystemHUD = false

    var body: some View {
        Form {
            Section {
                Toggle("Mostrar el volumen", isOn: $showVolume)
                Toggle("Mostrar porcentaje en vez de barra", isOn: $showPercentage)
            }
            Section {
                Toggle("Sustituir los avisos de volumen y brillo de macOS", isOn: $replaceSystemHUD)
            } footer: {
                Text("Necesita el permiso de Accesibilidad. También activa el aviso de brillo en la isla.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct CalendarSettings: View {
    @AppStorage(Preference.showCalendar) private var showCalendar = false
    @AppStorage(Preference.eventReminder) private var eventReminder = true
    @AppStorage(Preference.eventMinutes) private var eventMinutes = 5
    @AppStorage(Preference.soundCalendar) private var soundCalendar = true

    var body: some View {
        Form {
            Section {
                Toggle("Mostrar próximos eventos en la isla", isOn: $showCalendar)
            } footer: {
                Text("Te pedirá permiso para leer tu calendario. Los eventos no salen de tu Mac.")
            }
            Section("Recordatorio") {
                Toggle("Avisar antes de cada evento", isOn: $eventReminder)
                Stepper("\(eventMinutes) min antes", value: $eventMinutes, in: 1...60)
                    .disabled(!eventReminder)
                Toggle("Sonido del recordatorio", isOn: $soundCalendar)
            }
            .disabled(!showCalendar)
        }
        .formStyle(.grouped)
    }
}

final class LoginItem: ObservableObject {
    @Published var error: String?
    @Published var isEnabled = SMAppService.mainApp.status == .enabled {
        didSet {
            guard isEnabled != oldValue else { return }
            do {
                if isEnabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
