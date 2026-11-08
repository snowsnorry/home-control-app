#if DEBUG
import AppKit
import SwiftUI

struct DysonDiagnosticView: View {
    @Bindable var experiment: DysonDiagnostic

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Эксперимент Dyson TP07").font(.title2.bold())
            Text("История из MyDyson и живые данные с очистителя. Вход сохраняется в Связке ключей и используется основным приложением.")
                .foregroundStyle(.secondary)

            if experiment.devices.isEmpty {
                signIn
            } else {
                history
            }
            if experiment.canRecordLive {
                Divider()
                live
            }

            Divider()
            Button("Открыть папку с результатами") {
                NSWorkspace.shared.open(experiment.directory)
            }
        }
        .padding(24)
        .frame(width: 540)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Email MyDyson", text: $experiment.email)
            TextField("Код страны аккаунта", text: $experiment.country)
            Button(experiment.codeSent ? "Запросить новый код" : "Получить код по почте") {
                Task { await experiment.requestCode() }
            }
            .disabled(experiment.email.isEmpty || experiment.country.count != 2)

            if experiment.codeSent {
                SecureField("Пароль MyDyson", text: $experiment.password)
                SecureField("Код из письма", text: $experiment.code)
                Button(experiment.sessionSavePending ? "Повторить сохранение" : "Войти") { Task { await experiment.signIn() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!experiment.sessionSavePending && (experiment.password.isEmpty || experiment.code.isEmpty))
            }
            if !experiment.signInStatus.isEmpty {
                Text(experiment.signInStatus).foregroundStyle(.secondary)
            }
        }
        .disabled(experiment.signingIn)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Очиститель", selection: $experiment.selectedSerial) {
                ForEach(experiment.devices) { device in
                    Text(device.name + " · " + device.serial.suffix(4)).tag(device.serial)
                }
            }
            .disabled(experiment.capturing || experiment.readingHistory)
            .onChange(of: experiment.selectedSerial) { experiment.fillHost() }

            Divider()
            Text("История MyDyson").font(.headline)
            Button("Загрузить историю") { Task { await experiment.readHistory() } }
                .disabled(experiment.readingHistory)
            if !experiment.historyStatus.isEmpty {
                Text(experiment.historyStatus).foregroundStyle(.secondary)
            }
        }
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Живые данные TP07").font(.headline)
            if experiment.devices.isEmpty {
                Text("Можно использовать сохранённое подключение Home Control без входа в MyDyson.")
                    .foregroundStyle(.secondary)
            }
            TextField("IP или локальное имя очистителя", text: $experiment.host)
                .disabled(experiment.capturing)
            Text("Во время записи можно переключать режим с пульта или из MyDyson. Запись только читает данные.")
                .foregroundStyle(.secondary)
            HStack {
                if experiment.capturing {
                    Button("Завершить запись") { experiment.stopLive() }
                    Text("Пакетов: \(experiment.packetCount)").monospacedDigit()
                } else {
                    Button("Начать запись на 3 минуты") { experiment.startLive() }
                        .disabled(experiment.host.isEmpty)
                }
            }
            if !experiment.liveStatus.isEmpty {
                Text(experiment.liveStatus).foregroundStyle(.secondary)
            }
            if !experiment.latestState.isEmpty {
                Text(experiment.latestState).font(.system(.caption, design: .monospaced))
            }
        }
    }
}
#endif
