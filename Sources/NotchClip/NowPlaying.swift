import AppKit
import Foundation

// Что играет в системе (Now Playing). С macOS 15.4 MediaRemote не отдаёт сведения обычным процессам,
// поэтому данные читает маленький помощник, загруженный в /usr/bin/perl (системный бинарник с доступом).
// Помощник собирается из `NowPlayingHelper.source` в dylib и печатает одну строку JSON при изменении
// (и heartbeat раз в 5 с). Команды приходят в stdin строками play/pause/toggle/next/previous.

// MARK: - Данные от помощника

enum NowPlayingStatus: Equatable { case stopped, paused, playing }

/// Одна строка JSON от помощника.
struct NowPlayingSnapshot: Equatable {
    enum Playback: String, Equatable { case playing, paused, none }

    var playback: Playback
    /// Bundle id приложения-источника, например "ru.yandex.desktop.music".
    var bundleID: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    /// Позиция в момент `timestamp` (epoch, секунды).
    var elapsed: Double
    var rate: Double
    var timestamp: TimeInterval
    var artworkID: String
    var artworkData: Data?

    static func parse(_ line: String) -> NowPlayingSnapshot? {
        guard let data = line.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              let playback = Playback(rawValue: wire.state) else { return nil }
        return NowPlayingSnapshot(
            playback: playback,
            bundleID: wire.bundle ?? "",
            title: wire.title ?? "",
            artist: wire.artist ?? "",
            album: wire.album ?? "",
            duration: wire.duration ?? 0,
            elapsed: wire.elapsed ?? 0,
            rate: wire.rate ?? 0,
            timestamp: wire.timestamp ?? 0,
            artworkID: wire.artworkId ?? "",
            artworkData: wire.artworkData.flatMap { Data(base64Encoded: $0) }
        )
    }

    private struct Wire: Decodable {
        let state: String
        let bundle: String?
        let title: String?
        let artist: String?
        let album: String?
        let duration: Double?
        let elapsed: Double?
        let rate: Double?
        let timestamp: Double?
        let artworkId: String?
        let artworkData: String?
    }
}

// MARK: - Редьюсер: playing / paused / stopped с устареванием

/// Хранит последний снимок и решает, что показывать. Без снимка или при молчании дольше `staleAfter` — stopped.
struct NowPlayingReducer: Equatable {
    /// Помощник шлёт heartbeat раз в 5 с, поэтому 12 с тишины означают, что он умер или завис.
    static let staleAfter: TimeInterval = 12

    private(set) var snapshot: NowPlayingSnapshot?
    private(set) var receivedAt: TimeInterval = 0

    mutating func receive(_ newSnapshot: NowPlayingSnapshot, at now: TimeInterval) {
        snapshot = newSnapshot
        receivedAt = now
    }

    mutating func reset() {
        snapshot = nil
        receivedAt = 0
    }

    func status(at now: TimeInterval) -> NowPlayingStatus {
        guard let snapshot, now - receivedAt < Self.staleAfter else { return .stopped }
        switch snapshot.playback {
        case .playing: return .playing
        case .paused: return .paused
        case .none: return .stopped
        }
    }
}

// MARK: - Время и прогресс

enum NowPlayingClock {
    /// Текущая позиция. Во время игры экстраполируем от момента замера; всегда в пределах [0, duration].
    static func elapsed(_ snapshot: NowPlayingSnapshot, at now: TimeInterval) -> Double {
        guard snapshot.playback == .playing else { return clamp(snapshot.elapsed, duration: snapshot.duration) }
        let rate = snapshot.rate > 0 ? snapshot.rate : 1
        let advanced = snapshot.elapsed + max(0, now - snapshot.timestamp) * rate
        return clamp(advanced, duration: snapshot.duration)
    }

    static func clamp(_ value: Double, duration: Double) -> Double {
        let lower = max(0, value)
        return duration > 0 ? min(lower, duration) : lower
    }

    static func progress(elapsed: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    /// "3:05" до часа, "1:02:05" от часа. Отрицательные значения считаются нулём.
    static func format(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// "-1:23": сколько осталось до конца.
    static func remaining(elapsed: Double, duration: Double) -> String {
        "-" + format(max(0, duration - elapsed))
    }
}

// MARK: - Источник и команды

enum NowPlayingSource {
    static let names: [String: String] = [
        "ru.yandex.desktop.music": "Яндекс Музыка",
        "com.apple.Music": "Музыка",
        "com.spotify.client": "Spotify",
        "com.google.Chrome": "Chrome",
        "com.apple.Safari": "Safari",
    ]

    static func displayName(bundleID: String) -> String {
        if let name = names[bundleID] { return name }
        return bundleID.split(separator: ".").last.map(String.init) ?? "Плеер"
    }
}

enum NowPlayingCommand: String, CaseIterable {
    case play, pause, toggle, next, previous
}

enum NowPlayingSettings {
    /// Ключ настройки "Музыка в островке" (по умолчанию включено).
    static let key = "liveActivityMusic"

    static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

// MARK: - Цвета: обложка, акцент, настройки оформления

struct RGB8: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    var nsColor: NSColor {
        NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

extension RGB8 {
    /// Акцент по умолчанию (#FF9F0A) и запасной цвет при испорченной настройке.
    static let accentDefault = RGB8(r: 255, g: 159, b: 10)

    /// Разбор "#RRGGBB" (решётка необязательна). Некорректная строка даёт nil.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(r: UInt8((value >> 16) & 0xFF), g: UInt8((value >> 8) & 0xFF), b: UInt8(value & 0xFF))
    }

    /// Из цвета системы в sRGB (для ColorPicker). Цвета без пространства sRGB дают nil.
    init?(nsColor: NSColor) {
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> UInt8 { UInt8(min(255, max(0, (value * 255).rounded()))) }
        self.init(r: channel(rgb.redComponent), g: channel(rgb.greenComponent), b: channel(rgb.blueComponent))
    }

    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
}

/// Режим цвета музыки: эквалайзер и прогресс мини-плеера.
enum MusicColorMode: String, CaseIterable {
    case artwork
    case accent
    case custom
}

/// Ключи настроек оформления (UserDefaults). UI в SettingsView, потребители читают те же ключи.
enum AppearanceSettings {
    static let accentKey = "appearanceAccent"
    static let musicColorKey = "appearanceMusicColor"
    static let musicCustomKey = "appearanceMusicCustomColor"
    static let accentDefaultHex = RGB8.accentDefault.hex
    static let musicColorDefault = MusicColorMode.accent.rawValue
}

enum DominantColor {
    /// Доминирующий цвет: пиксели группируются по 4 битам на канал, вес растёт с насыщенностью.
    /// Почти чёрные, почти белые и серые пиксели отбрасываются, если есть цветные. Пустой вход даёт nil.
    static func pick(_ pixels: [RGB8]) -> RGB8? {
        guard !pixels.isEmpty else { return nil }
        let colorful = pixels.filter { !isNeutral($0) }
        let source = colorful.isEmpty ? pixels : colorful

        var buckets: [Int: (count: Int, r: Int, g: Int, b: Int, score: Double)] = [:]
        for pixel in source {
            let key = (Int(pixel.r >> 4) << 8) | (Int(pixel.g >> 4) << 4) | Int(pixel.b >> 4)
            var bucket = buckets[key] ?? (0, 0, 0, 0, 0)
            bucket.count += 1
            bucket.r += Int(pixel.r)
            bucket.g += Int(pixel.g)
            bucket.b += Int(pixel.b)
            bucket.score += 0.25 + saturation(pixel)
            buckets[key] = bucket
        }
        // При равном весе побеждает меньший ключ, чтобы результат не зависел от порядка обхода словаря.
        guard let best = buckets.max(by: { lhs, rhs in
            lhs.value.score != rhs.value.score ? lhs.value.score < rhs.value.score : lhs.key > rhs.key
        }) else { return nil }
        let bucket = best.value
        return RGB8(r: UInt8(bucket.r / bucket.count), g: UInt8(bucket.g / bucket.count), b: UInt8(bucket.b / bucket.count))
    }

    static func saturation(_ pixel: RGB8) -> Double {
        let high = Double(max(pixel.r, pixel.g, pixel.b))
        let low = Double(min(pixel.r, pixel.g, pixel.b))
        return high == 0 ? 0 : (high - low) / high
    }

    static func isNeutral(_ pixel: RGB8) -> Bool {
        max(pixel.r, pixel.g, pixel.b) < 30 || min(pixel.r, pixel.g, pixel.b) > 225 || saturation(pixel) < 0.12
    }

    /// Цвет для чёрного фона: яркость поднимается до 180, оттенок сохраняется.
    static func visible(_ color: RGB8) -> RGB8 {
        let high = max(color.r, color.g, color.b)
        guard high > 0, high < 180 else { return color }
        let scale = 180 / Double(high)
        func lift(_ value: UInt8) -> UInt8 { UInt8(min(255, (Double(value) * scale).rounded())) }
        return RGB8(r: lift(color.r), g: lift(color.g), b: lift(color.b))
    }
}

enum ArtworkSampler {
    /// Уменьшает картинку до side×side и отдаёт пиксели RGB (без альфы).
    static func pixels(of image: NSImage, side: Int = 24) -> [RGB8] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let count = side * side * 4
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 4)
        defer { buffer.deallocate() }
        guard let context = CGContext(
            data: buffer, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        let bytes = buffer.bindMemory(to: UInt8.self, capacity: count)
        var result: [RGB8] = []
        result.reserveCapacity(side * side)
        for index in stride(from: 0, to: count, by: 4) {
            result.append(RGB8(r: bytes[index], g: bytes[index + 1], b: bytes[index + 2]))
        }
        return result
    }
}

// MARK: - Эквалайзер

enum NowPlayingEqualizer {
    /// Статичные высоты (0...1) для паузы и для "Уменьшить движение".
    static let resting: [Double] = [0.45, 0.8, 0.6]

    /// Высоты трёх столбиков в момент `time`. На паузе всегда `resting`.
    static func heights(at time: TimeInterval, playing: Bool) -> [Double] {
        guard playing else { return resting }
        return (0..<3).map { index in
            let phase = time * (3.1 + Double(index) * 0.9) + Double(index) * 1.7
            return 0.3 + 0.7 * (0.5 + 0.5 * sin(phase))
        }
    }
}

// MARK: - Помощник: исходник, сборка dylib и процесс

enum NowPlayingHelper {
    /// Минимальный Objective-C код: MediaRemote-запросы, JSON-строки в stdout, команды из stdin.
    static let source = #"""
    #import <Foundation/Foundation.h>
    #include <dlfcn.h>
    #include <pthread.h>
    #include <stdio.h>
    #include <string.h>
    #include <unistd.h>
    #include <time.h>

    typedef void (^InfoHandler)(CFDictionaryRef);
    typedef void (^ClientHandler)(void *);
    typedef void (^BoolHandler)(Boolean);
    typedef void (*GetInfoFn)(dispatch_queue_t, InfoHandler);
    typedef void (*GetClientFn)(dispatch_queue_t, ClientHandler);
    typedef CFStringRef (*ClientBundleFn)(void *);
    typedef void (*GetIsPlayingFn)(dispatch_queue_t, BoolHandler);
    typedef Boolean (*SendCommandFn)(uint32_t, CFDictionaryRef);

    static GetInfoFn getInfo;
    static GetClientFn getClient;
    static ClientBundleFn clientBundle;
    static GetIsPlayingFn getIsPlaying;
    static SendCommandFn sendCommand;
    static dispatch_queue_t mrQueue;

    static void loadSymbols(void) {
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        getInfo = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        getClient = dlsym(h, "MRMediaRemoteGetNowPlayingClient");
        clientBundle = dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
        getIsPlaying = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        sendCommand = dlsym(h, "MRMediaRemoteSendCommand");
        mrQueue = dispatch_queue_create("notchclip.nowplaying", DISPATCH_QUEUE_SERIAL);
    }

    static NSDictionary *fetchSnapshot(void) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSDictionary *info = nil;
        getInfo(mrQueue, ^(CFDictionaryRef dict) {
            if (dict) info = [(__bridge NSDictionary *)dict copy];
            dispatch_semaphore_signal(done);
        });
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        if (!info) { out[@"state"] = @"none"; return out; }

        dispatch_semaphore_t playingDone = dispatch_semaphore_create(0);
        __block BOOL playing = NO;
        getIsPlaying(mrQueue, ^(Boolean value) { playing = value; dispatch_semaphore_signal(playingDone); });
        dispatch_semaphore_wait(playingDone, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));

        dispatch_semaphore_t clientDone = dispatch_semaphore_create(0);
        __block NSString *bundle = @"";
        getClient(mrQueue, ^(void *client) {
            if (client) {
                CFStringRef b = clientBundle(client);
                if (b) bundle = [(__bridge NSString *)b copy];
            }
            dispatch_semaphore_signal(clientDone);
        });
        dispatch_semaphore_wait(clientDone, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));

        out[@"state"] = playing ? @"playing" : @"paused";
        out[@"bundle"] = bundle;
        out[@"title"] = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";
        out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
        out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
        out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
        out[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
        out[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @0;
        NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        out[@"timestamp"] = @(stamp ? stamp.timeIntervalSince1970 : [[NSDate date] timeIntervalSince1970]);
        out[@"artworkId"] = info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"] ?: @"";
        NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if (art) out[@"artworkData"] = [art base64EncodedStringWithOptions:0];
        return out;
    }

    static void *commandReader(void *unused) {
        char line[64];
        while (fgets(line, sizeof line, stdin)) {
            line[strcspn(line, "\r\n")] = 0;
            uint32_t cmd = UINT32_MAX;
            if (!strcmp(line, "play")) cmd = 0;
            else if (!strcmp(line, "pause")) cmd = 1;
            else if (!strcmp(line, "toggle")) cmd = 2;
            else if (!strcmp(line, "next")) cmd = 4;
            else if (!strcmp(line, "previous")) cmd = 5;
            if (cmd != UINT32_MAX) sendCommand(cmd, NULL);
        }
        // stdin closed: the app is gone. Exit instead of polling forever as an orphan.
        _exit(0);
        return NULL;
    }

    void nowplaying_run(void) {
        @autoreleasepool {
            loadSymbols();
            pthread_t reader;
            pthread_create(&reader, NULL, commandReader, NULL);
            NSString *lastSig = nil;
            NSString *lastArtId = nil;
            time_t lastEmit = 0;
            for (;;) {
                @autoreleasepool {
                    NSMutableDictionary *snap = [fetchSnapshot() mutableCopy];
                    NSString *sig = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@|%@",
                                     snap[@"state"], snap[@"bundle"], snap[@"title"], snap[@"artist"],
                                     snap[@"album"], snap[@"duration"], snap[@"rate"], snap[@"artworkId"]];
                    time_t now = time(NULL);
                    if (![sig isEqualToString:lastSig] || now - lastEmit >= 5) {
                        NSString *artId = snap[@"artworkId"] ?: @"";
                        if ([artId isEqualToString:lastArtId]) [snap removeObjectForKey:@"artworkData"];
                        lastArtId = artId;
                        NSData *json = [NSJSONSerialization dataWithJSONObject:snap options:0 error:nil];
                        if (json) {
                            fwrite(json.bytes, 1, json.length, stdout);
                            fputc('\n', stdout);
                            fflush(stdout);
                        }
                        lastSig = sig;
                        lastEmit = now;
                    }
                }
                sleep(1);
            }
        }
    }
    """#

    /// Загрузчик для /usr/bin/perl: грузит dylib и запускает `nowplaying_run`, который не возвращается.
    static let perlLoader = #"""
    require DynaLoader;
    my $lib = $ARGV[0];
    my $handle = DynaLoader::dl_load_file($lib, 0) or die("load: " . DynaLoader::dl_error() . "\n");
    my $symbol = DynaLoader::dl_find_symbol($handle, "nowplaying_run") or die("symbol: " . DynaLoader::dl_error() . "\n");
    my $xs = DynaLoader::dl_install_xsub("main::nowplaying_run", $symbol, $lib);
    &$xs;
    """#

    /// Собирает dylib в `directory` (имя содержит хеш исходника). Нужны команды разработчика (clang из CLT).
    static func library(in directory: URL) throws -> URL {
        let fileManager = FileManager.default
        if let bundled = Bundle.main.url(forResource: "nowplaying", withExtension: "dylib") { return bundled }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = "nowplaying-\(fnv1a(source))"
        let dylib = directory.appendingPathComponent("\(stem).dylib")
        if fileManager.fileExists(atPath: dylib.path) { return dylib }

        let compiler = "/usr/bin/clang"
        guard fileManager.fileExists(atPath: compiler), developerToolsInstalled() else {
            throw NowPlayingError.toolsMissing
        }
        let sourceFile = directory.appendingPathComponent("\(stem).m")
        try source.write(to: sourceFile, atomically: true, encoding: .utf8)
        let temporary = directory.appendingPathComponent("\(stem)-\(UUID().uuidString).dylib")
        let status = try run(compiler, ["-dynamiclib", "-fobjc-arc", "-framework", "Foundation",
                                        "-o", temporary.path, sourceFile.path])
        guard status == 0 else { throw NowPlayingError.compileFailed }
        try fileManager.moveItem(at: temporary, to: dylib)
        return dylib
    }

    /// Процесс помощника: stdout — строки JSON, stdin — команды.
    static func process(library: URL) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", perlLoader, library.path]
        return process
    }

    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func developerToolsInstalled() -> Bool {
        guard let output = try? runCapturing("/usr/bin/xcode-select", ["-p"]) else { return false }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func runCapturing(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

enum NowPlayingError: Error, Equatable {
    case toolsMissing
    case compileFailed
}

// MARK: - Монитор

/// Держит процесс помощника, пока `setActive(true)`. Вызывать только когда островок или панель видны и настройка включена.
@MainActor
final class NowPlayingMonitor: ObservableObject {
    @Published private(set) var status: NowPlayingStatus = .stopped
    @Published private(set) var snapshot: NowPlayingSnapshot?
    @Published private(set) var artwork: NSImage?
    /// Цвет эквалайзера: доминирующий цвет обложки, поднятый для чёрного фона.
    @Published private(set) var tint: RGB8 = RGB8(r: 255, g: 149, b: 0)
    @Published private(set) var errorMessage: String?

    private let directory: URL
    private var reducer = NowPlayingReducer()
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var active = false
    private var restarts = 0
    private var startedAt: Date?
    private var artworkID = ""
    private var staleTimer: Timer?

    init(directory: URL = NowPlayingMonitor.defaultDirectory) {
        self.directory = directory
    }

    nonisolated static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("NotchClip/NowPlaying", isDirectory: true)
    }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            restarts = 0
            launch()
            staleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshStatus() }
            }
        } else {
            staleTimer?.invalidate()
            staleTimer = nil
            stopProcess()
            reducer.reset()
            publish(status: .stopped, snapshot: nil)
            artwork = nil
            artworkID = ""
        }
    }

    func send(_ command: NowPlayingCommand) {
        guard let input else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data((command.rawValue + "\n").utf8))
    }

    // MARK: Процесс

    private func launch() {
        let directory = directory
        Task { @MainActor in
            do {
                let library = try await Task.detached(priority: .utility) {
                    try NowPlayingHelper.library(in: directory)
                }.value
                guard active, process == nil else { return }
                startProcess(library: library)
            } catch {
                errorMessage = (error as? NowPlayingError) == .toolsMissing
                    ? "Нужны инструменты разработчика (xcode-select --install)."
                    : "Не удалось подготовить помощника музыки."
            }
        }
    }

    private func startProcess(library: URL) {
        let process = NowPlayingHelper.process(library: library)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            Task { @MainActor in self?.consume(chunk) }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            Task { @MainActor in
                guard let self, let process, self.process === process else { return }
                self.processEnded()
            }
        }
        do {
            try process.run()
            self.process = process
            self.startedAt = Date()
            self.input = input
            self.output = output
            errorMessage = nil
        } catch {
            errorMessage = "Не удалось запустить помощника музыки."
        }
    }

    private func stopProcess() {
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        input = nil
        output = nil
        buffer.removeAll()
    }

    private func processEnded() {
        // A helper that lived a while was healthy: only quick crashes count toward the retry limit.
        if let startedAt, Date().timeIntervalSince(startedAt) > 60 { restarts = 0 }
        startedAt = nil
        stopProcess()
        reducer.reset()
        publish(status: .stopped, snapshot: nil)
        guard active, restarts < 3 else { return }
        restarts += 1
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if active, process == nil { launch() }
        }
    }

    // MARK: Разбор строк

    private func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8),
                  let parsed = NowPlayingSnapshot.parse(line) else { continue }
            receive(parsed)
        }
    }

    private func receive(_ parsed: NowPlayingSnapshot) {
        reducer.receive(parsed, at: Date().timeIntervalSince1970)
        updateArtwork(parsed)
        refreshStatus()
    }

    private func updateArtwork(_ parsed: NowPlayingSnapshot) {
        if parsed.artworkID != artworkID || parsed.artworkData != nil {
            artworkID = parsed.artworkID
            if let data = parsed.artworkData, let image = NSImage(data: data) {
                artwork = image
                let pixels = ArtworkSampler.pixels(of: image)
                if let dominant = DominantColor.pick(pixels) {
                    tint = DominantColor.visible(dominant)
                }
            } else if parsed.artworkID.isEmpty {
                artwork = nil
                tint = RGB8(r: 255, g: 149, b: 0)
            }
        }
    }

    private func refreshStatus() {
        publish(status: reducer.status(at: Date().timeIntervalSince1970), snapshot: reducer.snapshot)
    }

    private func publish(status newStatus: NowPlayingStatus, snapshot newSnapshot: NowPlayingSnapshot?) {
        if status != newStatus { status = newStatus }
        if snapshot != newSnapshot { snapshot = newSnapshot }
    }
}
