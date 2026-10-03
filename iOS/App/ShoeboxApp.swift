import BackgroundTasks
import ShoeboxCore
import SwiftUI

@main
struct ShoeboxApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await model.onForeground() }
            case .background:
                BackgroundRefresh.schedule(nextDue: model.nextDue)
            default:
                break
            }
        }
        // The upload extension does the uploading. This refresh task only makes
        // sure a due snapshot gets started even if the extension is idle.
        .backgroundTask(.appRefresh(AppEnvironment.refreshTaskID)) {
            let outcome = await AppModel.runEngineOnce()
            let next = (try? EngineFactory.make().currentState()).flatMap { state -> Date? in
                let settings = SettingsRepository().loadSettings()
                return settings.schedule.nextDue(lastCompletedStart: state.lastCompleted?.startedAt)
            }
            BackgroundRefresh.schedule(nextDue: outcome == .processing ? nil : next)
        }
    }
}

enum BackgroundRefresh {
    /// Ask iOS to wake the app around the next due date (iOS decides exactly
    /// when). With no date, try again in a few hours.
    static func schedule(nextDue: Date?) {
        let request = BGAppRefreshTaskRequest(identifier: AppEnvironment.refreshTaskID)
        let fallback = Date().addingTimeInterval(6 * 3600)
        request.earliestBeginDate = max(nextDue ?? fallback, Date().addingTimeInterval(15 * 60))
        try? BGTaskScheduler.shared.submit(request)
    }
}
