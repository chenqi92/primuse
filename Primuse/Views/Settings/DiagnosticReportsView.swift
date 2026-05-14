import SwiftUI

/// Settings → 关于 → 诊断报告。显示由 MetricKit 上报的 crash / hang 报告
/// 列表,点击可以分享 (邮件 / AirDrop / 复制) 给开发者排查。报告全部本地
/// 存放,不会自动外发。
struct DiagnosticReportsView: View {
    @State private var reports: [DiagnosticReport] = []
    @State private var showClearConfirm = false
    private let service: CrashDiagnosticsService

    init(service: CrashDiagnosticsService) {
        self.service = service
    }

    var body: some View {
        List {
            if reports.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 36))
                            .foregroundStyle(.green)
                        Text(String(localized: "diagnostics_empty_title"))
                            .font(.headline)
                        Text(String(localized: "diagnostics_empty_subtitle"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section {
                    ForEach(reports) { report in
                        ShareLink(item: report.url) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(report.displayDate)
                                        .font(.subheadline)
                                    Text(report.displaySize)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text(String(localized: "diagnostics_footer"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label(String(localized: "diagnostics_clear"), systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(String(localized: "diagnostics_title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .confirmationDialog(
            String(localized: "diagnostics_clear_confirm"),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "diagnostics_clear"), role: .destructive) {
                service.clearAll()
                reload()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
    }

    private func reload() {
        reports = service.reports()
    }
}
