import SwiftUI

struct CastSheet: View {
    let url: String
    let title: String

    @ObservedObject private var cast = CastService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var casting: DLNADevice?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if cast.scanning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在搜索同一 Wi-Fi 下的设备…").font(.subheadline).foregroundStyle(Theme.subtext)
                        }
                    } else if cast.devices.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("没有发现设备").font(.subheadline)
                            Text("手机和电视/投影仪需要连接同一个路由器，并确认设备已开机")
                                .font(.caption).foregroundStyle(Theme.subtext)
                        }
                        .padding(.vertical, 6)
                    } else {
                        ForEach(cast.devices) { device in
                            Button {
                                casting = device
                                Task {
                                    await cast.cast(url: url, title: title, device: device)
                                    if cast.connected != nil { dismiss() }
                                    casting = nil
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "tv")
                                        .font(.system(size: 18))
                                        .foregroundStyle(Theme.brand)
                                        .frame(width: 34, height: 34)
                                        .background(Theme.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name).font(.subheadline).foregroundStyle(Theme.text)
                                        Text(device.serviceType.contains("AVTransport") ? "支持边播边控" : "基础投屏")
                                            .font(.caption2).foregroundStyle(Theme.subtext)
                                    }
                                    Spacer()
                                    if casting?.id == device.id {
                                        ProgressView()
                                    } else if cast.connected?.id == device.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.brand)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                } header: {
                    Text("投屏到")
                } footer: {
                    if let err = cast.lastError {
                        Text(err).foregroundStyle(.red)
                    }
                }

                if let connected = cast.connected {
                    Section {
                        Button(role: .destructive) {
                            Task {
                                await cast.stop()
                                dismiss()
                            }
                        } label: {
                            Text("断开 \(connected.name)")
                        }
                    }
                }
            }
            .navigationTitle("投屏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await cast.scan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(cast.scanning)
                }
            }
            .task {
                if cast.devices.isEmpty { await cast.scan() }
            }
        }
    }
}
